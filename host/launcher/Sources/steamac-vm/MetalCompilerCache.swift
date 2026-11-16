import CryptoKit
import Darwin
import Foundation
import Metal

/// STEAMAC-2E: Metal's frontend cannot compile monolithic_metal.pcm in an inaccessible or
/// immutable cache. TMPDIR does not redirect confstr(_CS_DARWIN_USER_CACHE_DIR). Metal's
/// optional cache-path SPI must run before any device/library or cache getter is used.
/// The SPI redirects both com.apple.metal (library cache) and com.apple.metalfe (module cache).
/// The library cache is capped at 1 GiB, evicts oldest first and keys entries by the bundle's
/// resourcePath, so app copies sharing one bundle id evict each other's shaders: each copy gets
/// its own directory. App Translocation runs a quarantined copy from a new random path on every
/// launch: those launches share one directory.
enum MetalCompilerCache {
    private typealias SetPath = @convention(c) (UnsafeRawPointer) -> Void
    private(set) static var outcome = "unprepared"
    private static var startupDetail = ""

    private static func setPath(_ path: String) throws {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "MTLSetShaderCachePath") else {
            throw OptionError("Metal cache-path override is unavailable on this macOS")
        }
        // The SPI takes an NSString, not a C string; Metal copies its filesystem representation.
        let string = path as NSString
        withExtendedLifetime(string) {
            unsafeBitCast(symbol, to: SetPath.self)(Unmanaged.passUnretained(string).toOpaque())
        }
    }

    static func prepare() {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard count > 0, count <= buffer.count else {
            outcome = "cache-directory-unavailable"
            log("Metal compiler cache: cannot locate DARWIN_USER_CACHE_DIR (\(String(cString: strerror(errno))))")
            return
        }
        let (primary, fallback) = paths(userCache: String(cString: buffer), home: NSHomeDirectory(),
                                        bundleID: Bundle.main.bundleIdentifier, bundlePath: Bundle.main.bundlePath)
        if Bundle.main.bundlePath.hasSuffix(".app") { adoptLegacyCache(primary: primary) }
        do { log("Metal shader cache: \(try prepare(primary: primary, fallback: fallback))") }
        catch {
            startupDetail = "\(error)"
            log("Metal compiler cache: cannot use a writable replacement: \(error)")
        }
    }

    static func paths(userCache: String, home: String, bundleID: String?, bundlePath: String) -> (primary: String, fallback: String) {
        let name = directoryName(bundlePath: bundlePath)
        return (userCache + (bundleID ?? LauncherSettings.defaultDomain) + "/" + name,
                home + "/Library/Caches/" + LauncherSettings.defaultDomain + "/" + name)
    }

    /// Builds before the per-copy cache used Metal's default <bundle id>/com.apple.metal, which has the
    /// same layout: the first app copy that starts after the update takes it over, so its shaders do
    /// not compile again (a bare development binary does not).
    static func adoptLegacyCache(primary: String) {
        let legacy = (primary as NSString).deletingLastPathComponent + "/com.apple.metal"
        guard !FileManager.default.fileExists(atPath: primary), FileManager.default.fileExists(atPath: legacy) else { return }
        do {
            try FileManager.default.moveItem(atPath: legacy, toPath: primary)
            log("Metal shader cache: moved \(legacy) to \(primary)")
        } catch {
            log("Metal shader cache: cannot move \(legacy): \(error)")
        }
    }

    static func directoryName(bundlePath: String) -> String {
        let path = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        guard !path.contains("/AppTranslocation/") else { return "metal-translocated" }
        return "metal-" + SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// Probe the existing module tree, not just its parent: one stale immutable .pcm or hash
    /// directory is enough to break compilation. Do not change ownership, ACLs or file flags,
    /// and never delete the original cache (another VM process may still be using it).
    /// Returns the directory Metal now uses.
    @discardableResult
    static func prepare(primary: String, fallback: String) throws -> String {
        do {
            try checkWritableTree(primary)
            outcome = "override-unavailable"
            try setPath(primary)
            outcome = "primary"
            startupDetail = primary
            log("Metal compiler cache: primary writable at startup: \(primary)")
            return primary
        } catch {
            let reason = "\(error)"
            startupDetail = "\(primary): \(reason)"
            outcome = "replacement-unwritable"
            try checkWritableTree(fallback)
            outcome = "override-unavailable"
            try setPath(fallback)
            outcome = "redirected"
            log("Metal compiler cache: \(primary) is not writable (\(reason)); using \(fallback) before Metal initialises")
            return fallback
        }
    }

    /// A startup probe cannot predict later filesystem/security-policy changes (STEAMAC-7W).
    /// Preserve the startup decision and the actual failed module's metadata in the next report.
    /// This is read-only: Metal chooses its cache once; never change it while compiles are running.
    static func failureDiagnostics(_ message: String) -> String? {
        guard message.contains("monolithic_metal.pcm"),
              let start = message.range(of: "unable to open output file '")?.upperBound,
              let end = message[start...].firstIndex(of: "'") else { return nil }
        let path = String(message[start..<end])
        guard path.hasSuffix("/monolithic_metal.pcm") else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        var lines = ["reporter-startup=\(outcome) reporter-detail=\(startupDetail); VM startup decision is the metal_cache tag"]
        for item in [(directory as NSString).deletingLastPathComponent, directory, path] {
            var info = stat()
            if lstat(item, &info) == 0 {
                lines.append("\(item): uid=\(info.st_uid) gid=\(info.st_gid) mode=\(String(info.st_mode, radix: 8)) flags=0x\(String(info.st_flags, radix: 16)) writable=\(access(item, W_OK) == 0)")
            } else {
                lines.append("\(item): lstat errno=\(errno) \(String(cString: strerror(errno)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func checkWritableTree(_ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try probeDirectory(path)
        var enumerationError: Error?
        guard let entries = fm.enumerator(at: URL(fileURLWithPath: path),
                                          includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                          errorHandler: { _, error in enumerationError = error; return false }) else {
            throw OptionError("\(path): cannot enumerate module cache")
        }
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw OptionError("\(url.path): symbolic link in module cache")
            }
            if values.isDirectory == true {
                try probeDirectory(url.path)
            } else if url.pathExtension == "pcm" {
                let fd = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw OptionError("\(url.path): \(String(cString: strerror(errno)))") }
                close(fd)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private static func probeDirectory(_ path: String) throws {
        let probe = path + "/.steamac-write-probe-" + UUID().uuidString
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw OptionError("\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd); unlink(probe) }
        var byte: UInt8 = 0
        guard Darwin.write(fd, &byte, 1) == 1 else {
            throw OptionError("\(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Each compilation runs in a fresh process so Metal's dispatch_once cache-path selection
    /// cannot hide a bad override. Only private temporary caches are touched, never the VM cache.
    static func selfTest() -> Never {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["STEAMAC_METAL_CACHE_SELFTEST_ROOT"],
           let mode = environment["STEAMAC_METAL_CACHE_SELFTEST_MODE"] {
            do {
                let primary = root + (mode == "healthy" ? "/own" : mode == "late-blocked" ? "/late-primary" : "/blocked"), fallback = root + "/replacement"
                if mode == "blocked" {
                    try setPath(primary)
                } else if mode == "late-blocked" {
                    guard try prepare(primary: primary, fallback: fallback) == primary, outcome == "primary" else {
                        throw OptionError("healthy startup cache was not recorded")
                    }
                    guard chflags(primary, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags late cache") }
                } else {
                    let want = mode == "healthy" ? primary : fallback
                    guard try prepare(primary: primary, fallback: fallback) == want else {
                        throw OptionError("\(mode): Metal does not use \(want)")
                    }
                }
                guard let device = MTLCreateSystemDefaultDevice() else { throw OptionError("no Metal device") }
                let options = MTLCompileOptions()
                options.languageVersion = .version3_0
                let source = "#include <metal_stdlib>\nusing namespace metal; kernel void cacheProbe\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))(device float* output [[buffer(0)]], uint tid [[thread_position_in_grid]]) { output[tid] = sin(float(tid)); }"
                do {
                    _ = try device.makeLibrary(source: source, options: options)
                    guard mode != "blocked" else { throw OptionError("blocked cache unexpectedly compiled") }
                    if mode == "healthy" {
                        guard FileManager.default.subpaths(atPath: primary)?.contains(where: { $0.hasSuffix("/libraries.list") }) == true else {
                            throw OptionError("Metal library cache is not in \(primary)")
                        }
                    }
                    log("selftest-metal-cache: PASS Metal source compiles with \(mode == "healthy" ? "this copy's own cache" : "replacement cache")")
                } catch {
                    let detail = "\(error)"
                    guard mode == "blocked" || mode == "late-blocked", detail.contains("monolithic_metal.pcm"),
                          detail.contains("Operation not permitted"), detail.contains("could not build module") else { throw error }
                    if mode == "late-blocked" {
                        guard let diagnostics = failureDiagnostics(detail),
                              diagnostics.contains("startup=primary"), diagnostics.contains("flags=0x2") else {
                            throw OptionError("runtime cache failure lost startup outcome or immutable flag")
                        }
                        chflags(primary, 0)
                    }
                    log("selftest-metal-cache: PASS reproduced \(mode) module-cache failure: \(detail)")
                }
                exit(0)
            } catch {
                log("selftest-metal-cache: FAIL \(error)")
                exit(1)
            }
        }
        let root = NSTemporaryDirectory() + "steamac-metal-cache-" + UUID().uuidString
        let blocked = root + "/blocked"
        do {
            try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: true)
            guard chflags(blocked, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags: \(String(cString: strerror(errno)))") }
            for mode in ["blocked", "repaired", "healthy", "late-blocked"] {
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = ["--selftest-metal-cache"]
                var childEnvironment = environment
                childEnvironment["STEAMAC_METAL_CACHE_SELFTEST_ROOT"] = root
                childEnvironment["STEAMAC_METAL_CACHE_SELFTEST_MODE"] = mode
                process.environment = childEnvironment
                try process.run()
                process.waitUntilExit()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw OptionError("\(mode) child failed: \(process.terminationStatus)")
                }
            }
            guard try prepare(primary: root + "/healthy", fallback: root + "/unused") == root + "/healthy", outcome == "primary" else {
                throw OptionError("healthy per-copy cache was not used")
            }
            guard !FileManager.default.fileExists(atPath: root + "/unused") else {
                throw OptionError("healthy cache created an unnecessary replacement")
            }
            let nested = root + "/nested/hash"
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
            guard chmod(nested, 0o500) == 0 else { throw OptionError("chmod nested cache") }
            var rejected = false
            do { try checkWritableTree(root + "/nested") } catch { rejected = true }
            chmod(nested, 0o700)
            guard rejected else { throw OptionError("unwritable hash directory was not detected") }
            let pcm = nested + "/monolithic_metal.pcm"
            try Data([0]).write(to: URL(fileURLWithPath: pcm))
            guard chflags(pcm, UInt32(UF_IMMUTABLE)) == 0 else { throw OptionError("chflags module") }
            rejected = false
            do { try checkWritableTree(root + "/nested") } catch { rejected = true }
            chflags(pcm, 0)
            guard rejected else { throw OptionError("immutable existing module was not detected") }
            log("selftest-metal-cache: PASS inaccessible hash directory and immutable existing module detected")
            let fm = FileManager.default
            let copies = ["/a/FX Steam Launcher.app", "/b/FX Steam Launcher.app", "/AppTranslocation/X1/d/FX Steam Launcher.app",
                          "/AppTranslocation/X2/d/FX Steam Launcher.app"].map { root + "/apps" + $0 }
            for copy in copies { try fm.createDirectory(atPath: copy, withIntermediateDirectories: true) }
            try fm.createSymbolicLink(atPath: root + "/apps/link.app", withDestinationPath: copies[0])
            func cache(_ app: String) -> String { paths(userCache: root + "/cache/", home: root + "/home", bundleID: "id", bundlePath: app).primary }
            let own = cache(copies[0])
            let legacy = root + "/cache/id/com.apple.metal/32024"
            try fm.createDirectory(atPath: legacy, withIntermediateDirectories: true)
            try Data([0]).write(to: URL(fileURLWithPath: legacy + "/libraries.list"))
            adoptLegacyCache(primary: own)
            adoptLegacyCache(primary: cache(copies[1]))
            guard fm.fileExists(atPath: own + "/32024/libraries.list"), !fm.fileExists(atPath: cache(copies[1])) else {
                throw OptionError("the old shared cache did not move to the first copy's directory")
            }
            guard own.hasPrefix(root + "/cache/id/metal-"), cache(copies[0] + "/") == own, cache(root + "/apps/link.app") == own else {
                throw OptionError("one app copy reached by another path gets another cache directory: \(own), \(cache(root + "/apps/link.app"))")
            }
            guard cache(copies[1]) != own else { throw OptionError("two app copies share one cache directory") }
            guard cache(copies[2]) == cache(copies[3]), cache(copies[2]) == root + "/cache/id/metal-translocated" else {
                throw OptionError("translocated launches get new cache directories: \(cache(copies[2])), \(cache(copies[3]))")
            }
            guard directoryName(bundlePath: "/nonexistent/FX Steam Launcher.app") == "metal-5a55a084f63f" else {
                throw OptionError("cache directory name changed: \(directoryName(bundlePath: "/nonexistent/FX Steam Launcher.app"))")
            }
            chflags(blocked, 0)
            try fm.removeItem(atPath: root)
            log("selftest-metal-cache: PASS each app copy gets its own stable cache directory, translocated launches share one")
            log("selftest-metal-cache: PASS healthy per-copy cache is used without a replacement; all passed")
            exit(0)
        } catch {
            chflags(blocked, 0)
            chflags(root + "/late-primary", 0)
            chmod(root + "/nested/hash", 0o700)
            chflags(root + "/nested/hash/monolithic_metal.pcm", 0)
            try? FileManager.default.removeItem(atPath: root)
            log("selftest-metal-cache: FAIL \(error)")
            exit(1)
        }
    }
}
