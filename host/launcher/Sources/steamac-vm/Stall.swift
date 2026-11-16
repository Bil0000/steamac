import AppKit
import Darwin
import QuartzCore

/// "Loading…" indicator (Settings > General). Shown after `ready`, never during the
/// boot/shutdown overlay, when the guest sends no GPU work for `idleThreshold` while a game has
/// focus (`focus game <appid>`; the idle Steam UI legitimately sends none for minutes), or —
/// whatever has focus — when the guest's heartbeat has also stopped for `heartbeatTimeout`.
/// Hidden as soon as GPU work arrives (not while `gameDark`: a loading game's window is still
/// black), the game loses focus or the guest answers again. No
/// heartbeat is expected between sessions (the agent ends with each gamescope session, gaming or
/// Desktop Mode), and both clocks start over after the VM was paused (suspend, guest sleep) or
/// the Mac slept.
///
/// GPU work = libkrun's krun_gpu_get_activity counters (libkrun patch 0015), sampled every
/// `tick`: virtio-gpu control-queue commands (SUBMIT_3D, RESOURCE_FLUSH, SET_SCANOUT*, …) and
/// Venus commands virglrenderer dispatched from its in-process rings (virglrenderer patch 0009).
/// The idle window starts at the latest of: last GPU work, gate opening (overlay gone, setting
/// on), the game getting focus — so stale idle time never fires at once. The wording comes from
/// the guest agent's heartbeat (`alive <uptime_ms> <loadavg1>` once a second over fx.progress)
/// and this process's CPU time (vCPU threads included): alive → "Loading…" + CPU, no
/// heartbeat for `heartbeatTimeout` → "SteamOS is not responding…". With perf stats on it also
/// logs the counter rates and the longest idle stretch every 5 s.
///
/// A launch that seems stuck: the focused game has not drawn yet (`gameDark`), the GPU has been
/// idle for `hungThreshold` and the game's cgroups used less than `hungCores` over that time
/// (the heartbeat's game CPU field; older agents send none and never get the prompt). The card
/// then says "<Game> may be stuck" with "Restart game" (`onRestartGame`) and "Keep waiting",
/// which keeps the prompt away until that game draws. A busy CPU (shader compile, x86
/// translation) never prompts. Main thread only.
final class StallMonitor {
    typealias Counters = (ctrl: UInt64, ring: UInt64)

    static let idleThreshold: TimeInterval = 2
    static let heartbeatTimeout: TimeInterval = 5
    static let tick: TimeInterval = 0.25
    static let perfPeriod: TimeInterval = 5
    static let hungThreshold: TimeInterval = 60
    static let hungCores = 0.1

    struct Diagnostic {
        let idle: TimeInterval
        let heartbeatAge: TimeInterval
        let history: String
        let memoryHistory: String
        let threadSnapshot: String
    }

    private struct Reading {
        let at: CFTimeInterval
        let counters: Counters?
        let heartbeatAge: TimeInterval?
        let uptimeMs: Int
        let load: Double
        let cpu: Double
        let pollGap: TimeInterval
        let game: Bool
        let gate: Bool
        let hostActive: Bool
        let hostKey: Bool
        let hostWindow: String
    }
    // Independent of Settings > Performance statistics: reports otherwise had only the first
    // 2 s of GPU idleness and could not distinguish agent loss, host scheduling and GPU stalls.
    private var readings: [Reading] = []
    private var nextReading = 0
    private var lastReading: CFTimeInterval = 0
    private var lastPoll: CFTimeInterval = 0
    private var guestUptimeMs = 0
    // A delayed main-queue timer cannot establish guest silence: queued progress
    // callbacks have not had a chance to run either (STEAMAC-8).
    private var heartbeatObservationStarted = CACurrentMediaTime()

    let view: StallIndicatorView
    /// nil = no counters (VM not running, no GPU): never shows.
    private let sample: () -> Counters?
    private var timer: DispatchSourceTimer?
    /// Timer suspended while its gate is closed (kept in step with resume/suspend: libdispatch
    /// aborts the process on an unbalanced suspend, so `stop()` must resume before cancelling).
    private var timerSuspended = false
    private var counters: Counters?
    private var countersAvailable = false
    private var lastActivity = CACurrentMediaTime()
    private var cpuAtActivity = StallMonitor.cpuSeconds()
    /// When the gate last opened (enabled, not suppressed, game focus): idle time counts from
    /// here at the earliest.
    private var gateOpenedAt = CACurrentMediaTime()
    private var lastAlive: CFTimeInterval = 0
    private var guestLoad = 0.0
    /// Per-second CPU readings while shown: (time, process CPU seconds).
    private var cpuSamples: [(CFTimeInterval, Double)] = []
    /// The focused game's CPU seconds from the heartbeat: (time, seconds), about `hungThreshold` of them.
    private var gameCPUSamples: [(CFTimeInterval, Double)] = []
    /// "Keep waiting" was clicked for this game: no prompt until it draws or a new process of it
    /// starts (`game-start`).
    private var waited: Int?
    private var hungPrompt = false
    private var shownSince: (idleStart: CFTimeInterval, cpu: Double)?
    private var notRespondingReported = false
    private var longStallLogged = false
    // perf stats window
    private var perfStart: CFTimeInterval = 0
    private var perfCounters: Counters?
    private var perfLongestIdle: CFTimeInterval = 0

    /// Settings > General "Show indicator when the GPU goes idle".
    var enabled = true { didSet { if enabled != oldValue { gateChanged() } } }
    /// Before `ready`, boot / shutdown overlay on screen, or the guest is shutting down.
    var suppressed = true { didSet { if suppressed != oldValue { gateChanged() } } }
    /// The game that has focus in the guest (`focus game <appid>`).
    var game: Int? {
        didSet {
            guard game != oldValue else { return }
            gameCPUSamples.removeAll()
            gateChanged()
        }
    }
    private var gameFocused: Bool { game != nil }
    /// The focused game is frozen (GamePause): an idle GPU is expected.
    var paused = false { didSet { if paused != oldValue { gateChanged() } } }
    /// The focused game shows no picture or a black one (NoPictureGuard): the card covers it even
    /// while the GPU works (a loading game).
    var gameDark = false {
        didSet {
            guard gameDark != oldValue else { return }
            gateChanged()
        }
    }
    /// Display name of the focused game, if known.
    var gameName: () -> String? = { nil }
    /// The indicator is up (or about to fade in).
    var indicatorShown: Bool { shownSince != nil }
    /// The may-be-stuck card asks the user (its links need the pointer).
    var asking: Bool { hungPrompt }
    /// Once per indicator stretch, when its wording turns to "SteamOS is not responding…".
    /// Recent counter/heartbeat samples accompany the report even when perf stats are off.
    var onNotResponding: ((Diagnostic) -> Void)?
    /// "Restart game" on the may-be-stuck card (argument: app id).
    var onRestartGame: ((Int) -> Void)?
    /// The card asks the user (its links need the pointer).
    var onAsk: (() -> Void)?

    init(view: StallIndicatorView, sample: @escaping () -> Counters?) {
        self.view = view
        self.sample = sample
        readings.reserveCapacity(32)
        VMMemoryDiagnostics.shared.start()
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + StallMonitor.tick, repeating: StallMonitor.tick, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        timerSuspended = false
        updateTimerState()
    }

    func stop() {
        // Never cancel a suspended source: libdispatch aborts the process on an unbalanced suspend.
        if timerSuspended { timer?.resume(); timerSuspended = false }
        timer?.cancel()
        timer = nil
        hide(reason: "stopped")
    }

    /// Timer suspended while its gate is closed: no 4 Hz main-queue wakeups
    /// while the indicator is off or suppressed.
    private func updateTimerState() {
        guard let timer, gateOpen == timerSuspended else { return }
        timerSuspended = !gateOpen
        if gateOpen { timer.resume() } else { timer.suspend() }
    }

    /// The VM ran again after a pause (suspend, guest sleep) or the Mac woke from sleep (stopped
    /// meanwhile): the guest could neither send GPU work nor heartbeats, so idle time and
    /// heartbeat age start over.
    func resumeAfterSuspend() {
        let now = CACurrentMediaTime()
        lastActivity = now
        cpuAtActivity = StallMonitor.cpuSeconds()
        gateOpenedAt = now
        if lastAlive > 0 { lastAlive = now }
        gameCPUSamples.removeAll()
        counters = nil
        lastPoll = now
        heartbeatObservationStarted = now
        start()
    }

    /// Guest heartbeat (`alive <uptime_ms> <loadavg1> [<game_cpu_s>]`).
    func alive(uptimeMs: Int, load: Double, gameCPU: Double? = nil) {
        lastAlive = CACurrentMediaTime()
        guestLoad = load
        guestUptimeMs = uptimeMs
        guard let gameCPU, gameFocused else { return gameCPUSamples.removeAll() }
        // A smaller total: a new game process.
        if let last = gameCPUSamples.last, gameCPU < last.1 { gameCPUSamples.removeAll() }
        gameCPUSamples.append((lastAlive, gameCPU))
        while gameCPUSamples.count > 2, gameCPUSamples[1].0 <= lastAlive - StallMonitor.hungThreshold { gameCPUSamples.removeFirst() }
    }

    /// The game showed its first picture (NoPictureGuard; not a pause or sleep that only closes
    /// its gate): "Keep waiting" is over.
    func gameDrew(_ appid: Int) {
        if waited == appid { waited = nil }
    }

    /// `game-start`: a new process of the game (a relaunch) gets the prompt again.
    func gameStarted(_ appid: Int) {
        if waited == appid { waited = nil }
    }

    /// The focused game has not drawn, its GPU idled and its CPU stayed near zero for `hungThreshold`.
    private func hung(_ now: CFTimeInterval) -> Bool {
        guard coversDarkGame, game != waited, !notResponding(at: now),
              now - max(lastActivity, gateOpenedAt) >= StallMonitor.hungThreshold,
              let first = gameCPUSamples.first, let last = gameCPUSamples.last,
              first.0 <= now - StallMonitor.hungThreshold, last.0 > first.0 else { return false }
        return (last.1 - first.1) / (last.0 - first.0) < StallMonitor.hungCores
    }

    /// The agent ended with the gamescope session (bare `focus desktop`: Switch to Desktop, Return
    /// to Gaming Mode, relogin): no heartbeat is expected until the next session's agent sends one.
    func heartbeatsEnded() {
        guard lastAlive > 0 else { return }
        lastAlive = 0
        log("stall: guest agent ended with its session; no heartbeat expected until it is back")
        evaluate(CACurrentMediaTime())
    }

    private var gateOpen: Bool { enabled && !suppressed && !paused }
    private var coversDarkGame: Bool { gameDark && gameFocused }

    /// Any gate input changed: a newly opened window starts now; a closed one hides at once.
    private func gateChanged() {
        let now = CACurrentMediaTime()
        if gateOpen { gateOpenedAt = now }
        evaluate(now)
        updateTimerState()
    }

    // MARK: sampling

    private func poll() {
        let now = CACurrentMediaTime()
        if lastPoll > 0 && now - lastPoll > Self.heartbeatTimeout {
            heartbeatObservationStarted = now
            log("stall: host polling gap \(String(format: "%.2f", now - lastPoll)) s; observing fresh heartbeat window")
        }
        let c = sample()
        let active: Bool
        noteReading(now: now, counters: c)
        if let c, let prev = counters { active = c != prev } else { active = false }
        if let c { counters = c }
        perfNote(now: now, counters: c, active: active)
        countersAvailable = c != nil
        if active {
            if !coversDarkGame { hide(reason: nil, now: now) }
            lastActivity = now
            cpuAtActivity = StallMonitor.cpuSeconds()
            if !coversDarkGame { return }
        }
        evaluate(now)
    }

    /// Show / refresh / hide the indicator for the current state (no GPU work since `lastActivity`).
    private func evaluate(_ now: CFTimeInterval) {
        let dead = notResponding(at: now)
        // Durations shown and logged are the GPU's whole idle time.
        guard countersAvailable, gateOpen, gameFocused || dead,
              coversDarkGame || now - max(lastActivity, gateOpenedAt) >= StallMonitor.idleThreshold else {
            if shownSince != nil {
                let response = (heartbeatAge(at: now) ?? 0) > Self.heartbeatTimeout
                    ? "host observation restarted" : "guest responding again"
                hide(reason: !enabled ? "setting off" : suppressed ? "overlay"
                     : notRespondingReported && !dead ? response
                     : gameFocused ? "game picture back" : "game focus lost", now: now)
            }
            return
        }
        noteCPU(now)
        let starting = shownSince == nil
        if starting { shownSince = (lastActivity, cpuAtActivity) }
        let stuck = hung(now)
        if stuck != hungPrompt {
            hungPrompt = stuck
            if stuck {
                log("stall: game \(game ?? 0) may be stuck (gpu idle \(Int(now - lastActivity)) s, game CPU \(gameCPUText)), asking")
                onAsk?()
            }
            view.showsSpinner = !stuck
            view.actions = stuck ? [
                (String(localized: "Restart game", comment: "Button on the may-be-stuck card"), { [weak self] in self?.restartGame() }),
                (String(localized: "Keep waiting", comment: "Button on the may-be-stuck card"), { [weak self] in self?.keepWaiting() }),
            ] : []
        }
        let (title, detail) = stuck ? stuckText() : text(now: now, idle: now - lastActivity)
        view.showsReportLink = dead
        view.update(title: title, detail: detail)
        if starting {
            view.show()
            log((coversDarkGame ? "stall: game picture black" : "stall: gpu idle \(String(format: "%.1f", now - lastActivity)) s")
                + ", indicator shown (\(status(now)))")
        }
        if !notRespondingReported && dead {
            notRespondingReported = true
            log("stall: guest not responding (no heartbeat for \(Int(heartbeatAge(at: now) ?? 0)) s, gpu idle \(Int(now - lastActivity)) s)")
            onNotResponding?(Diagnostic(idle: now - lastActivity, heartbeatAge: heartbeatAge(at: now) ?? 0,
                                       history: diagnosticHistory(now: now),
                                       memoryHistory: VMMemoryDiagnostics.shared.history(),
                                       threadSnapshot: StallThreadDiagnostics.snapshot()))
        }
        if !longStallLogged && now - max(lastActivity, gateOpenedAt) >= 10 {
            longStallLogged = true
            for line in diagnosticHistory(now: now).split(separator: "\n") {
                log("stall: history \(line)")
            }
            for line in StallThreadDiagnostics.snapshot().split(separator: "\n") {
                log("stall: \(line)")
            }
        }
    }

    private func hide(reason: String?, now: CFTimeInterval = CACurrentMediaTime()) {
        guard let since = shownSince else { return }
        shownSince = nil
        notRespondingReported = false
        longStallLogged = false
        let duration = now - since.idleStart
        let cpu = duration > 0 ? (StallMonitor.cpuSeconds() - since.cpu) / duration : 0
        log("stall: gpu idle \(String(format: "%.1f", duration)) s (\(status(now, cpu: cpu)))"
            + (reason.map { ", ended by \($0)" } ?? ""))
        cpuSamples.removeAll()
        hungPrompt = false
        view.actions = []
        view.showsSpinner = true
        view.hide()
    }

    private func restartGame() {
        guard let game else { return }
        log("stall: restarting game \(game) (user choice)")
        gameCPUSamples.removeAll()
        gateOpenedAt = CACurrentMediaTime()
        onRestartGame?(game)
        evaluate(CACurrentMediaTime())
    }

    private func keepWaiting() {
        log("stall: keep waiting for game \(game ?? 0) (user choice)")
        waited = game
        evaluate(CACurrentMediaTime())
    }

    // MARK: wording

    private func heartbeatAge(at now: CFTimeInterval) -> CFTimeInterval? {
        lastAlive > 0 ? max(0, now - lastAlive) : nil
    }

    // One poll uses one timestamp, including after diagnostic persistence or UI work.
    // Advancing only the heartbeat clock mid-poll turns host paging into a guest hang
    // (STEAMAC-8 b546e448: last history hb=1.14, report hb=6).
    static func heartbeatTimedOut(at now: CFTimeInterval, lastAlive: CFTimeInterval,
                                  observationStarted: CFTimeInterval, lastPoll: CFTimeInterval) -> Bool {
        lastAlive > 0 && now - lastAlive > heartbeatTimeout
            && now - observationStarted > heartbeatTimeout
            && lastPoll > 0 && now - lastPoll <= heartbeatTimeout
    }

    private func notResponding(at now: CFTimeInterval) -> Bool {
        Self.heartbeatTimedOut(at: now, lastAlive: lastAlive,
                              observationStarted: heartbeatObservationStarted, lastPoll: lastPoll)
    }

    private func text(now: CFTimeInterval, idle: CFTimeInterval) -> (String, String) {
        if notResponding(at: now) {
            return (String(localized: "SteamOS is not responding…"), String(localized: "waiting (\(Int(idle)) s)"))
        }
        let title = gameName().map { String(localized: "Loading \($0)…", comment: "Card over a loading game: game name") }
            ?? String(localized: "Loading…")
        let cores = String(format: "%.1f", currentCPU())
        let detail = heartbeatAge(at: now).map { $0 <= Self.heartbeatTimeout } == true
            ? String(localized: "VM CPU \(cores) cores · guest alive")
            : String(localized: "VM CPU \(cores) cores")
        return (title, detail)
    }

    private func stuckText() -> (String, String) {
        (gameName().map { String(localized: "\($0) may be stuck", comment: "Card over a game that does not load: game name") }
            ?? String(localized: "The game may be stuck"), "")
    }

    private var gameCPUText: String {
        guard let a = gameCPUSamples.first, let b = gameCPUSamples.last, b.0 > a.0 else { return "unknown" }
        return String(format: "%.2f cores", (b.1 - a.1) / (b.0 - a.0))
    }

    /// For the log: "guest alive, CPU 2.9 cores".
    private func status(_ now: CFTimeInterval, cpu: Double? = nil) -> String {
        let guest: String
        if let age = heartbeatAge(at: now) {
            if age <= Self.heartbeatTimeout {
                guest = "guest alive, load \(String(format: "%.2f", guestLoad))"
            } else if notResponding(at: now) {
                guest = "guest not responding for \(Int(age)) s"
            } else {
                guest = "heartbeat delayed \(Int(age)) s, observing after host scheduling gap"
            }
        } else {
            guest = "no guest heartbeat"
        }
        return "\(guest), CPU \(String(format: "%.1f", cpu ?? currentCPU())) cores"
    }

    // MARK: CPU

    /// User + system CPU time of this process (all threads: vCPUs, GPU worker, renderer).
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    private func noteCPU(_ now: CFTimeInterval) {
        cpuSamples.append((now, StallMonitor.cpuSeconds()))
        // Keep ~1 s of readings (one per tick).
        while let first = cpuSamples.first, now - first.0 > 1.01, cpuSamples.count > 2 { cpuSamples.removeFirst() }
    }

    /// Cores busy over the last second (since the idle start until a second of readings exists).
    private func currentCPU() -> Double {
        if cpuSamples.count >= 2, let a = cpuSamples.first, let b = cpuSamples.last, b.0 - a.0 >= 0.5 {
            return max(0, (b.1 - a.1) / (b.0 - a.0))
        }
        guard let since = shownSince else { return 0 }
        let dt = CACurrentMediaTime() - since.idleStart
        return dt > 0 ? max(0, (StallMonitor.cpuSeconds() - since.cpu) / dt) : 0
    }

    // MARK: stall evidence

    private func noteReading(now: CFTimeInterval, counters: Counters?) {
        let gap = lastPoll > 0 ? now - lastPoll : 0
        lastPoll = now
        guard now - lastReading >= 1 else { return }
        lastReading = now
        // Guest game focus is not host application focus (STEAMAC-8N/8P).
        // Keep presentation state in the same bounded timeline as GPU activity:
        // otherwise a later foreground report cannot establish when occlusion began.
        let window = view.window
        let windowState: String
        if let window {
            windowState = window.isMiniaturized ? "miniaturized"
                : !window.isVisible ? "hidden"
                : window.occlusionState.contains(.visible) ? "visible" : "occluded"
        } else {
            windowState = "detached"
        }
        let reading = Reading(at: now, counters: counters, heartbeatAge: heartbeatAge(at: now),
                              uptimeMs: guestUptimeMs, load: guestLoad, cpu: Self.cpuSeconds(),
                              pollGap: gap, game: gameFocused, gate: gateOpen,
                              hostActive: NSApp.isActive, hostKey: window?.isKeyWindow ?? false,
                              hostWindow: windowState)
        if readings.count < 32 {
            readings.append(reading)
        } else {
            readings[nextReading] = reading
        }
        nextReading = (nextReading + 1) % 32
        CrashReporting.updateGPUHistory(diagnosticHistory(now: now) + "\n" + VMMemoryDiagnostics.shared.history())
    }

    // Unlabelled neighbouring counters can resemble a payment-card number to
    // Sentry's scrubber (1.9.9 events 3859f512 / 4b047457, STEAMAC-8).
    static func diagnosticCounterText(_ counters: Counters?) -> String {
        counters.map { "ctrl=\($0.ctrl) ring=\($0.ring)" } ?? "ctrl=unavailable ring=unavailable"
    }

    private func diagnosticHistory(now: CFTimeInterval) -> String {
        var lines = ["GPU activity samples (ago seconds; counters cumulative; CPU cumulative seconds)"]
        for offset in 0..<readings.count {
            let r = readings[(readings.count == 32 ? nextReading + offset : offset) % 32]
            let heartbeat = r.heartbeatAge.map { String(format: "%.2f", $0) } ?? "none"
            lines.append(String(format: "ago=%.2f ", now - r.at) + Self.diagnosticCounterText(r.counters)
                         + " hb=\(heartbeat) up=\(r.uptimeMs)"
                         + String(format: " load=%.2f cpu=%.2f gap=%.2f", r.load, r.cpu, r.pollGap)
                         + " game=\(r.game) gate=\(r.gate)"
                         + " host-active=\(r.hostActive) host-key=\(r.hostKey) window=\(r.hostWindow)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: perf stats

    private func perfNote(now: CFTimeInterval, counters c: Counters?, active: Bool) {
        guard PerfStats.shared != nil else { perfStart = 0; return }
        if perfStart == 0 {
            perfStart = now
            perfCounters = c
            perfLongestIdle = 0
        }
        if !active { perfLongestIdle = max(perfLongestIdle, now - max(lastActivity, perfStart)) }
        guard now - perfStart >= StallMonitor.perfPeriod - StallMonitor.tick / 2 else { return }
        let dt = now - perfStart
        if let c, let p = perfCounters {
            perfLog(String(format: "perf: gpu ctrl/s=%.1f ring/s=%.1f longest-idle=%.2f s",
                       Double(c.ctrl &- p.ctrl) / dt, Double(c.ring &- p.ring) / dt, perfLongestIdle))
        } else {
            perfLog("perf: gpu counters unavailable")
        }
        perfStart = now
        perfCounters = c
        perfLongestIdle = 0
    }
}

/// The indicator: a translucent card in the lower third with a spinner and two lines of text,
/// over the last guest frame (FX overlay colors). Never takes mouse events, except on its links
/// ("Report…" while it says SteamOS is not responding, `actions`); when hidden it is `isHidden`
/// with every animation removed.
final class StallIndicatorView: NSView {
    private let card = CALayer()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let detailLayer = CATextLayer()
    private var linkLayers: [CATextLayer] = []
    private var title = ""
    private var detail = ""
    private(set) var shown = false
    private var fading = false
    /// Shown or hidden (after the fade-out), and the "Report…" link placed or removed on a card
    /// already shown: the window hides the Mac cursor over the picture and shows it over the
    /// link, so it re-decides then.
    var onVisibilityChange: (() -> Void)?

    var currentTitle: String { title }
    var currentDetail: String { detail }
    /// The card and the spinner, in view coordinates (self-test pixel checks).
    var cardFrame: CGRect { card.frame }
    var spinnerFrame: CGRect { arc.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY) }
    /// "Report…" on the card (Report a Problem), in view coordinates; empty when not shown.
    var reportLinkFrame: CGRect { hasReportLink ? linkFrames[0] : .zero }
    /// Every link on the card ("Report…" first, then `actions`), in view coordinates.
    var linkFrames: [CGRect] { linkLayers.map { $0.frame.offsetBy(dx: card.frame.minX, dy: card.frame.minY) } }
    private var hasReportLink: Bool { showsReportLink && onReport != nil }
    /// Links after "Report…": title and click action.
    var actions: [(title: String, action: () -> Void)] = [] {
        didSet {
            guard actions.map(\.title) != oldValue.map(\.title) else { return }
            reportLinkChanged = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var currentActions: [String] { actions.map(\.title) }
    /// The spinner (hidden for a notice that waits on the user).
    var showsSpinner = true { didSet { if showsSpinner != oldValue { needsLayout = true } } }
    /// Opens Report a Problem (the link is shown only when this is set).
    var onReport: (() -> Void)?
    /// The "not responding" wording: show the link.
    var showsReportLink = false {
        didSet {
            guard showsReportLink != oldValue else { return }
            reportLinkChanged = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// layout() places the link, then onVisibilityChange re-decides the cursor over it.
    private var reportLinkChanged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        autoresizingMask = [.width, .height]
        card.backgroundColor = OverlayView.color(0x171a21, 0.86)
        card.borderColor = OverlayView.color(0x66c0f4, 0.22)
        card.borderWidth = 1
        card.shadowColor = OverlayView.color(0x000000)
        card.shadowOpacity = 0.5
        card.shadowOffset = CGSize(width: 0, height: -2)
        track.fillColor = nil
        track.strokeColor = OverlayView.color(0xffffff, 0.1)
        arc.fillColor = nil
        arc.strokeColor = OverlayView.color(0x66c0f4)
        arc.lineCap = .round
        arc.strokeEnd = 0.7
        for t in [titleLayer, detailLayer] {
            t.alignmentMode = .left
            t.truncationMode = .end
            t.isWrapped = false
            card.addSublayer(t)
        }
        card.addSublayer(track)
        card.addSublayer(arc)
        layer!.addSublayer(card)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        let p = convert(point, from: superview)
        return linkFrames.contains { $0.contains(p) } ? self : nil
    }

    /// A link works with the click that activates the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard var i = linkFrames.firstIndex(where: { $0.contains(p) }) else { return }
        if hasReportLink {
            if i == 0 {
                log("stall: Report… clicked")
                onReport?()
                return
            }
            i -= 1
        }
        guard i < actions.count else { return }
        log("stall: \(actions[i].title) clicked")
        actions[i].action()
    }

    override func resetCursorRects() {
        for f in linkFrames { addCursorRect(f, cursor: .pointingHand) }
    }

    override var isOpaque: Bool { false }

    // MARK: visibility

    /// Fade in (0.25 s) and start the spinner.
    func show() {
        guard !shown || fading else { return }
        shown = true
        fading = false
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        startSpinner()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            animator().alphaValue = 1
        }
        onVisibilityChange?()
    }

    /// Fade out (0.2 s), then hide and drop every animation.
    func hide() {
        guard shown, !fading else { return }
        shown = false
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.fading = false
            guard !self.shown else { return }
            self.isHidden = true
            for l in [self.layer!, self.card, self.track, self.arc, self.titleLayer, self.detailLayer] + self.linkLayers { l.removeAllAnimations() }
            self.onVisibilityChange?()
        })
    }

    /// True when hidden and idle (no layer animations running).
    var isIdle: Bool {
        isHidden && ([layer!, card, track, arc, titleLayer, detailLayer] + linkLayers).allSatisfy { ($0.animationKeys() ?? []).isEmpty }
    }

    private func startSpinner() {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = 0.9
        a.repeatCount = .infinity
        arc.add(a, forKey: "spin")
    }

    // MARK: content

    func update(title: String, detail: String) {
        guard title != self.title || detail != self.detail else { return }
        // Same-length details (monospaced digits) keep the card's width: no relayout.
        let resize = title != self.title || detail.count != self.detail.count
        self.title = title
        self.detail = detail
        if resize { needsLayout = true } else { applyText() }
    }

    private var scaleFactor: CGFloat { max(0.85, min(1.6, min(bounds.width / 1280, bounds.height / 800))) }

    private var titleString: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 15 * scaleFactor, weight: .semibold),
            .foregroundColor: OverlayView.color(0xc7d5e0)])
    }

    private var detailString: NSAttributedString {
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * scaleFactor, weight: .regular),
            .foregroundColor: OverlayView.color(0x8f98a0)])
    }

    private func linkString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13 * scaleFactor, weight: .semibold),
            .foregroundColor: OverlayView.color(0x66c0f4),
            .underlineStyle: NSUnderlineStyle.single.rawValue])
    }

    private func applyText() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = titleString
        detailLayer.string = detailString
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        let k = scaleFactor
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let t = titleString, d = detailString
        let links = ((hasReportLink ? [String(localized: "Report…", comment: "Link to report an unresponsive VM to the developer")] : [])
                     + actions.map(\.title)).map(linkString)
        while linkLayers.count > links.count { linkLayers.removeLast().removeFromSuperlayer() }
        while linkLayers.count < links.count {
            let l = CATextLayer()
            l.alignmentMode = .left
            l.isWrapped = false
            card.addSublayer(l)
            linkLayers.append(l)
        }
        let pad = 18 * k, spin = showsSpinner ? 26 * k : 0, gap = 14 * k
        let textWidth = ceil(max(t.size().width, d.size().width)) + 2
        let linkWidths = links.map { ceil($0.size().width) + 2 }
        let linkSpace = linkWidths.reduce(0) { $0 + gap + $1 }
        let width = min(b.width - 32, pad + (showsSpinner ? spin + gap : 0) + textWidth + linkSpace + pad + 4 * k)
        let height = 62 * k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer!, card, track, arc, titleLayer, detailLayer] + linkLayers { l.contentsScale = scale }
        card.frame = CGRect(x: (b.width - width) / 2, y: (b.height * 0.26 - height / 2).rounded(), width: width, height: height).integral
        card.cornerRadius = 14 * k
        card.shadowRadius = 18 * k
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: card.cornerRadius, cornerHeight: card.cornerRadius, transform: nil)
        let spinFrame = CGRect(x: pad, y: (height - spin) / 2, width: spin, height: spin)
        let line = max(2, 2.6 * k)
        let circle = CGPath(ellipseIn: CGRect(x: line / 2, y: line / 2, width: spin - line, height: spin - line), transform: nil)
        for s in [track, arc] {
            s.frame = spinFrame
            s.path = circle
            s.lineWidth = line
            s.isHidden = !showsSpinner
        }
        let textX = pad + (showsSpinner ? spin + gap : 0)
        let textW = max(0, width - textX - pad - linkSpace)
        titleLayer.frame = CGRect(x: textX, y: detail.isEmpty ? (height - 20 * k) / 2 : height / 2 + 1 * k, width: textW, height: 20 * k)
        detailLayer.frame = CGRect(x: textX, y: height / 2 - 18 * k, width: textW, height: 16 * k)
        var linkX = width - pad - linkSpace
        for (i, l) in linkLayers.enumerated() {
            linkX += gap
            l.frame = CGRect(x: linkX, y: (height - 18 * k) / 2, width: linkWidths[i], height: 18 * k)
            l.string = links[i]
            linkX += linkWidths[i]
        }
        titleLayer.string = t
        detailLayer.string = d
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        if reportLinkChanged {
            reportLinkChanged = false
            onVisibilityChange?()
        }
    }

    /// Render the indicator (model values) over `background` at `scale` pixels per point.
    func renderImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        renderLayerImage(scale: scale, under: background)
    }
}

extension NSView {
    /// This layer-backed view (if shown) over `background` at `scale` pixels per point: window
    /// dumps of the cards over the guest frame. A hidden view returns a `background` of that size
    /// as is (no copy on the main thread).
    func renderLayerImage(scale: CGFloat, under background: CGImage?) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        let visible = !isHidden && alphaValue > 0
        if !visible, let background, background.width == w, background.height == h { return background }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background { ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if visible, let layer {
            ctx.saveGState()
            ctx.setAlpha(alphaValue)
            ctx.scaleBy(x: scale, y: scale)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
