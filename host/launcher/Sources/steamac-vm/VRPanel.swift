import AppKit
import Darwin
import Foundation
import SwiftUI

/// Settings > VR: what steamac-vrhost is doing (headset, stream, pairing) and how to set up a headset.
/// The data comes from the host's control socket (docs/vr-interfaces.md section 5): AF_UNIX SOCK_STREAM at
/// `VRControl.socketPath`, one request line, one JSON line back. Without a running host, the paired list and
/// unpairing go through the bundled executable (`--list-headsets --json`, `--unpair NAME`), which edits the same
/// store (~/Library/Application Support/steamac/vrhost/known_keys).
enum VRControl {
    /// The host's control socket (VRHost.start passes it as --control-socket); one VR host per user at a time.
    static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/steamac/vrhost/control.sock"
    }

    /// One request → the reply line, or nil when no host answers within `timeout`.
    static func request(_ line: String, path: String = socketPath, timeout: TimeInterval = 1) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }
        let req = Array((line + "\n").utf8)
        guard send(fd, req, req.count, 0) == req.count else { return nil }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while reply.count < 1 << 16 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            reply.append(buf, count: n)
            if buf[n - 1] == 0x0a { break }
        }
        return reply.isEmpty ? nil : reply
    }
}

/// The control socket's "status" reply (protocol version 1).
struct VRStatus: Decodable, Equatable {
    struct Headset: Decodable, Equatable {
        var name: String
        var eye_width: Int
        var eye_height: Int
        var render_width: Int?
        var render_height: Int?
        var refresh_hz: Double
        var refresh_rates: [Double]?
    }
    struct Stream: Decodable, Equatable {
        var frames: Int
        var bitrate_mbps: Double
        var target_mbps: Double
        var encode_ms: Double
        var decode_ms: Double
        var pipeline_ms: Double
    }
    var v: Int
    var state: String          // waiting | pairing | connected
    var port: Int
    var bonjour: String
    var encryption: String     // enabled | pairing | disabled
    var pin: String
    var headset: Headset?
    var stream: Stream
}

struct VRPairedHeadset: Decodable, Equatable, Identifiable {
    var name: String
    var last_connection: Int64
    var id: String { name }
}

private struct VRHeadsetList: Decodable { var headsets: [VRPairedHeadset] }
private struct VRError: Decodable { var error: String }

/// Which setup hint applies to a headset (WiVRn's headset_info system_name).
enum VRHeadsetFamily: Equatable {
    case questPico, steamFrame, other

    init(name: String) {
        let n = name.lowercased()
        if ["quest", "meta", "oculus", "pico"].contains(where: n.contains) { self = .questPico }
        else if n.contains("frame") || n.contains("valve") { self = .steamFrame }
        else { self = .other }
    }
}

/// Settings > VR state: polled once a second while the tab is visible. All text derivation is in pure
/// functions (`lines(...)`) so --selftest-vr checks it without a window.
@MainActor
final class VRPanelModel: ObservableObject {
    @Published private(set) var status: VRStatus?
    @Published private(set) var headsets: [VRPairedHeadset] = []
    @Published private(set) var lastError: String?

    let socketPath: String
    /// `nil` = VRHost.path (the bundled executable); the self-test passes its own.
    let executable: () -> String?
    private var timer: Timer?
    private var busy = false

    init(socketPath: String = VRControl.socketPath, executable: @escaping () -> String? = { VRHost.path }) {
        self.socketPath = socketPath
        self.executable = executable
    }

    var hostRunning: Bool { status != nil }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let path = socketPath, exe = executable()
        Task.detached {
            let status = VRControl.request("status", path: path).flatMap { try? JSONDecoder().decode(VRStatus.self, from: $0) }
            let list = status != nil
                ? VRControl.request("headsets", path: path).flatMap { try? JSONDecoder().decode(VRHeadsetList.self, from: $0) }?.headsets
                : Self.cliHeadsets(exe)
            await MainActor.run {
                self.status = status
                if let list { self.headsets = list }
                self.busy = false
            }
        }
    }

    /// Pairing on/off through the running host (WiVRn's "enable pairing": a fresh PIN each time).
    func setPairing(_ on: Bool) { send(on ? "pair on" : "pair off") }

    /// Unpair one headset ("" = all): through the host when it runs, else the executable.
    func unpair(_ name: String) {
        if hostRunning {
            send(name.isEmpty ? "unpair-all" : "unpair " + name)
            return
        }
        let exe = executable()
        Task.detached {
            if let exe { _ = Self.run(exe, name.isEmpty ? ["--unpair-all"] : ["--unpair", name]) }
            await MainActor.run { self.refresh() }
        }
    }

    private func send(_ line: String) {
        let path = socketPath
        Task.detached {
            let reply = VRControl.request(line, path: path)
            let error = reply.flatMap { try? JSONDecoder().decode(VRError.self, from: $0) }?.error
            await MainActor.run {
                self.lastError = reply == nil ? String(localized: "The VR host did not answer.") : error
                self.refresh()
            }
        }
    }

    nonisolated static func cliHeadsets(_ exe: String?) -> [VRPairedHeadset]? {
        guard let exe, let out = run(exe, ["--list-headsets", "--json"]) else { return nil }
        return out.split(separator: "\n").compactMap { try? JSONDecoder().decode(VRPairedHeadset.self, from: Data($0.utf8)) }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: text (pure)

    struct Lines: Equatable {
        var host: String
        var headset: String?
        var stream: String?
        var latency: String?
        var refresh: String?
        var bonjour: String
        var pin: String?
        var family: VRHeadsetFamily?
    }

    nonisolated static func lines(_ s: VRStatus?, available: Bool) -> Lines {
        guard let s else {
            return Lines(host: available ? String(localized: "Not running") : String(localized: "Not included in this build."),
                         bonjour: Host.current().localizedName ?? "")
        }
        var l = Lines(host: String(localized: "Running, port \(String(s.port))"),
                      bonjour: s.bonjour.isEmpty ? String(localized: "Not advertised") : s.bonjour,
                      pin: s.encryption == "pairing" && !s.pin.isEmpty ? s.pin : nil)
        if let h = s.headset {
            let hz = Int(h.refresh_hz.rounded())
            // sizes as text: a localized integer would get a grouping separator ("1.440")
            l.headset = String(localized: "\(h.name): \(String(h.eye_width))×\(String(h.eye_height)) per eye, \(hz) Hz")
            l.family = VRHeadsetFamily(name: h.name)
            l.refresh = String(localized: "\(hz) Hz")
            let rate = String(format: "%.1f", s.stream.bitrate_mbps), target = String(format: "%.0f", s.stream.target_mbps)
            l.stream = String(localized: "\(rate) of \(target) Mbit/s, \(s.stream.frames) frames sent")
            let enc = String(format: "%.1f", s.stream.encode_ms), dec = String(format: "%.1f", s.stream.decode_ms)
            if s.stream.pipeline_ms > 0 {
                let total = String(format: "%.1f", s.stream.pipeline_ms)
                l.latency = String(localized: "game frame to network \(total) ms, encode \(enc) ms, headset decode \(dec) ms")
            } else {
                l.latency = String(localized: "encode \(enc) ms, headset decode \(dec) ms")
            }
        } else {
            l.headset = s.state == "pairing" ? String(localized: "Waiting for a headset (pairing open)")
                                             : String(localized: "Waiting for a headset")
        }
        return l
    }
}

// MARK: - view

/// Settings > VR.
struct VRTab: View {
    @EnvironmentObject var settings: LauncherSettings
    @StateObject private var model = VRPanelModel()

    static let wivrnRelease = URL(string: "https://github.com/WiVRn/WiVRn/releases/tag/v26.9")!

    var body: some View {
        let l = VRPanelModel.lines(model.status, available: VRHost.path != nil)
        Form {
            Section {
                Toggle(isOn: $settings.vrEnabled) {
                    Label2(title: "VR (experimental)",
                           detail: String(localized: "DXMT path only: starts the bundled steamac-vrhost with the VM, which streams games' VR eye images to a standalone headset running the WiVRn v26.9 client on the same network. Games need an OpenVR runtime in the guest, which is not included yet. steamac-vrhost is GPL-3.0 software; see the licences in the app.")
                               + (VRHost.path == nil ? " " + String(localized: "Not included in this build.") : ""),
                           now: false, key: .vrEnabled)
                }
                .disabled(settings.graphicsPath != .dxmt || (VRHost.path == nil && !settings.vrEnabled))
            }

            Section {
                row("VR host", l.host,
                    detail: model.hostRunning ? nil
                        : settings.vrEnabled ? String(localized: "VR is on: the host starts with the VM (DXMT graphics path).")
                        : String(localized: "Turn on VR above, then start the VM."))
                if let h = l.headset { row("Headset", h) }
                if let s = l.stream { row("Stream", s) }
                if let lat = l.latency { row("Latency", lat) }
                row("Bonjour name", l.bonjour,
                    detail: String(localized: "Headsets on the same network list the Mac under this name; WiVRn can also connect by IP address."))
            } header: { Text("Status") }

            Section {
                if let pin = l.pin {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pairing PIN")
                            Text("Enter it in the WiVRn app on the new headset. The PIN never leaves this network.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(verbatim: pin).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    }
                    Button("Stop pairing") { model.setPairing(false) }
                } else {
                    HStack {
                        Button("Pair a new headset") { model.setPairing(true) }
                            .disabled(!model.hostRunning || model.status?.encryption == "disabled")
                        if !model.hostRunning {
                            Text("Needs the running VR host.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.headsets.isEmpty {
                    Text("No headset paired yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.headsets) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: h.name)
                                Text(lastConnected(h)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unpair") { model.unpair(h.name) }
                        }
                    }
                    if model.headsets.count > 1 { Button("Unpair all") { model.unpair("") } }
                }
                if let e = model.lastError {
                    Label { Text(verbatim: e) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Pairing") }

            Section {
                Picker(selection: $settings.vrEyeSize) {
                    Text("Headset default").tag("")
                    ForEach(eyeSizes, id: \.self) { s in
                        Text(verbatim: s.replacingOccurrences(of: "x", with: " × ")).tag(s)
                    }
                } label: {
                    Label2(title: "Resolution per eye",
                           detail: String(localized: "Size of the encoded image for each eye. Headset default uses what the headset asks for; a smaller size encodes faster, which high refresh rates need."),
                           now: false, key: .vrEyeSize)
                }
                Stepper(value: $settings.vrBitrateMbps, in: LauncherSettings.vrBitrateRange, step: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Label2(title: "Bitrate",
                               detail: String(localized: "Total for both eyes. Higher is sharper and needs a faster Wi-Fi link; the headset can lower it while streaming."),
                               now: false, key: .vrBitrateMbps)
                        Spacer()
                        Text("\(settings.vrBitrateMbps) Mbit/s").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                row("Refresh rate", l.refresh ?? String(localized: "Chosen by the headset"),
                    detail: String(localized: "Set in the WiVRn app on the headset; the host encodes at that rate."))
            } header: { Text("Encoder") }

            Section {
                hint(.questPico, l.family, title: "Meta Quest and Pico",
                     text: String(localized: "Install WiVRn v26.9 (WiVRn-release.apk from the release page) with adb in developer mode, and turn off automatic updates for WiVRn: a newer client does not connect."))
                hint(.steamFrame, l.family, title: "Steam Frame",
                     text: String(localized: "Build WiVRn's Linux client from the v26.9 tag (client on, server off) and connect to this Mac by IP address, port 9757."))
                Link("WiVRn v26.9 release", destination: Self.wivrnRelease)
            } header: { Text("Headset setup") } footer: {
                Text("steamac-vrhost is GPL-3.0 software based on WiVRn; its licence and source are listed in the app's licences.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// The presets plus a size set from the command line or `defaults`.
    private var eyeSizes: [String] {
        LauncherSettings.vrEyeSizes + (settings.vrEyeSize.isEmpty || LauncherSettings.vrEyeSizes.contains(settings.vrEyeSize)
                                       ? [] : [settings.vrEyeSize])
    }

    private func row(_ title: LocalizedStringKey, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Text(verbatim: value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func hint(_ family: VRHeadsetFamily, _ current: VRHeadsetFamily?, title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                if family == current { Text("connected").font(.caption).foregroundStyle(.green) }
            }
            Text(verbatim: text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lastConnected(_ h: VRPairedHeadset) -> String {
        guard h.last_connection > 0 else { return String(localized: "Never connected") }
        let when = Date(timeIntervalSince1970: TimeInterval(h.last_connection)).formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Last connected \(when)")
    }
}

// MARK: - self-test

/// The panel's part of `--selftest-vr` (VRSelfTest): text derivation from fixed replies, and the control
/// socket of a running host (status, pairing on/off with a fresh PIN, the paired list through the socket
/// and through the executable). Each function returns its number of failures.
enum VRPanelSelfTest {
    private static func check(_ ok: Bool, _ what: String, _ failures: inout Int) {
        if !ok { failures += 1; log("selftest-vr: FAIL panel: \(what)") }
    }

    static func text() -> Int {
        var f = 0
        let connected = #"{"v":1,"state":"connected","port":9757,"bonjour":"studio","encryption":"enabled","pin":"","#
            + #""headset":{"name":"Meta Quest 3","eye_width":1440,"eye_height":1584,"render_width":2064,"render_height":2208,"#
            + #""refresh_hz":90.0,"refresh_rates":[72,90,120]},"stream":{"frames":900,"bitrate_mbps":48.2,"target_mbps":50.0,"#
            + #""encode_ms":6.10,"decode_ms":7.25,"pipeline_ms":11.40}}"#
        let pairing = #"{"v":1,"state":"pairing","port":9757,"bonjour":"","encryption":"pairing","pin":"123456","headset":null,"#
            + #""stream":{"frames":0,"bitrate_mbps":0.0,"target_mbps":50.0,"encode_ms":0.00,"decode_ms":0.00,"pipeline_ms":0.00}}"#
        guard let c = try? JSONDecoder().decode(VRStatus.self, from: Data(connected.utf8)),
              let p = try? JSONDecoder().decode(VRStatus.self, from: Data(pairing.utf8)) else {
            check(false, "status replies do not decode", &f)
            return f
        }
        let lc = VRPanelModel.lines(c, available: true)
        check(lc.headset?.contains("Meta Quest 3") == true && lc.headset?.contains("1440×1584") == true && lc.headset?.contains("90") == true,
              "connected headset line: \(lc.headset ?? "-")", &f)
        check(lc.stream?.contains("48.2") == true && lc.stream?.contains("900") == true, "stream line: \(lc.stream ?? "-")", &f)
        check(lc.latency?.contains("11.4") == true && lc.latency?.contains("6.1") == true, "latency line: \(lc.latency ?? "-")", &f)
        check(lc.host.contains("9757"), "host line: \(lc.host)", &f)
        check(lc.refresh?.contains("90") == true && lc.pin == nil && lc.family == .questPico && lc.bonjour == "studio",
              "connected: refresh/pin/family/bonjour", &f)
        let lp = VRPanelModel.lines(p, available: true)
        check(lp.pin == "123456" && lp.stream == nil && lp.refresh == nil && lp.family == nil && lp.headset != nil,
              "pairing: PIN shown, no stream lines", &f)
        let off = VRPanelModel.lines(nil, available: true), absent = VRPanelModel.lines(nil, available: false)
        check(off.pin == nil && off.headset == nil && off.host != absent.host, "no host: running and not-built differ", &f)
        check(VRHeadsetFamily(name: "PICO 4 Ultra") == .questPico && VRHeadsetFamily(name: "Steam Frame") == .steamFrame
              && VRHeadsetFamily(name: "Lynx R1") == .other, "headset families", &f)
        let rows = "{\"name\":\"Quest \\\"A\\\"\",\"last_connection\":1760000000}\n{\"name\":\"Pico\",\"last_connection\":0}\n"
        let list = rows.split(separator: "\n").compactMap { try? JSONDecoder().decode(VRPairedHeadset.self, from: Data($0.utf8)) }
        check(list.map(\.name) == ["Quest \"A\"", "Pico"] && list[0].last_connection == 1_760_000_000, "--list-headsets --json rows", &f)
        return f
    }

    static func control(socket: String, executable: String, round: Int) -> Int {
        var f = 0
        func status(_ request: String) -> VRStatus? {
            // the host binds the socket right after it starts listening: allow it a moment
            for _ in 0..<50 {
                if let d = VRControl.request(request, path: socket) { return try? JSONDecoder().decode(VRStatus.self, from: d) }
                usleep(20_000)
            }
            return nil
        }
        guard let s = status("status") else {
            check(false, "round \(round): no status from the control socket \(socket)", &f)
            return f
        }
        // nothing paired in the scratch store: the host starts in pairing mode with a PIN
        check(s.v == 1 && s.state == "pairing" && s.encryption == "pairing" && s.port > 0 && s.headset == nil,
              "round \(round): status \(s)", &f)
        check(s.pin.count == 6 && s.pin.allSatisfy(\.isNumber), "round \(round): PIN '\(s.pin)'", &f)
        check(VRPanelModel.lines(s, available: true).pin == s.pin, "round \(round): panel does not show the PIN", &f)
        let offStatus = status("pair off")
        check(offStatus?.encryption == "enabled" && offStatus?.pin == "" && offStatus?.state == "waiting",
              "round \(round): pair off: \(String(describing: offStatus))", &f)
        check(VRPanelModel.cliHeadsets(executable) == [], "round \(round): --list-headsets --json of an empty store", &f)
        let on = status("pair on")
        check(on?.encryption == "pairing" && on?.pin.count == 6, "round \(round): pair on: \(String(describing: on))", &f)
        // the PIN file follows (what --show-pin prints)
        check(VRPanelModel.run(executable, ["--show-pin"])?.trimmingCharacters(in: .whitespacesAndNewlines) == on?.pin,
              "round \(round): --show-pin differs from the socket's PIN", &f)
        let list = VRControl.request("headsets", path: socket).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(list.contains("\"headsets\":[]"), "round \(round): headsets: \(list)", &f)
        let bad = VRControl.request("frobnicate", path: socket).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(bad.contains("\"error\""), "round \(round): unknown request: \(bad)", &f)
        log("selftest-vr: round \(round): control socket ok (port \(s.port), pairing off/on, PIN file, lists)")
        return f
    }
}
