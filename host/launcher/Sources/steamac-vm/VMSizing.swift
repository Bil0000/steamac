import Foundation

/// VM size this Mac gets when the user has not chosen one (Settings > Advanced "Automatic"; a
/// saved custom value or --cpus / --mem wins). Apple silicon's GPU has no memory of its own:
/// MoltenVK's device memory is the Mac's RAM, so guest RAM taken from an 8 GB Mac is GPU memory a
/// game no longer gets (STEAMAC-G: a MacBook Air M1 with 8 GB ran a 16 GB VM and the game lost its
/// device with kIOGPUCommandBufferCallbackErrorOutOfMemory).
enum VMSizing {
    /// What the automatic sizes are computed from.
    struct Host: Equatable {
        /// Physical RAM, bytes (hw.memsize).
        var memBytes: UInt64
        /// Cores that are not efficiency cores (every hw.perflevelN except the "Efficiency"
        /// level: newer chips can have more than one fast level, STEAMAC-2K); nil when the
        /// perflevel sysctls are missing.
        var perfCores: Int?
        /// All cores (activeProcessorCount).
        var cores: Int
        /// Memory macOS reports as available (availableMemory); nil when unknown. Other apps' memory
        /// is not available to the VM.
        var availBytes: UInt64? = nil

        /// The supervisor measures again before each boot (refresh) and hands the value to the VM
        /// process (availEnv), so both processes size the boot from one measurement.
        static var current = Host(memBytes: ProcessInfo.processInfo.physicalMemory,
                                  perfCores: fastCoreCount(),
                                  cores: ProcessInfo.processInfo.activeProcessorCount,
                                  availBytes: ProcessInfo.processInfo.environment[availEnv].flatMap(UInt64.init).map { $0 << 20 }
                                      ?? availableMemory())

        static func refresh() { current.availBytes = availableMemory() }

        var memGiB: Int { Int((memBytes + (1 << 29)) >> 30) }
        var availMiB: Int? { availBytes.map { Int($0 >> 20) } }
        var idle: Host { var h = self; h.availBytes = nil; return h }
        /// Cores a vCPU runs at full speed on.
        var fastCores: Int { perfCores ?? cores }
    }

    /// Where a boot's size came from.
    enum Source: String {
        case auto = "automatic", settings = "Settings", flag = "command line"
    }

    static let minAutoMemMiB = 4096, maxAutoMemMiB = 16384
    /// Smallest guest RAM a boot accepts (--mem; Options.validate). Saved settings are floored at 1024.
    static let minMemMiB = 256
    /// Fewer than 4 vCPUs leave Steam's UI loading for minutes (STEAMAC-2K: 2 vCPUs on a 12-core Mac).
    static let minAutoCPUs = 4, maxAutoCPUs = 8
    static let availEnv = "STEAMAC_AVAIL_MIB"
    /// macOS, the launcher, driver-internal allocations and other apps need room besides
    /// guest RAM and Vulkan heaps. Keep at least 3 GiB, or a quarter of a larger Mac.
    static func hostReserveMiB(_ host: Host) -> Int {
        max(3072, Int(host.memBytes >> 22))
    }

    static func headroomMiB(_ host: Host) -> Int {
        max(2048, Int(host.memBytes >> 24))
    }

    /// Shared by both host Vulkan drivers and the guest's VRAM reporting layer. This is
    /// an advertised working-set budget, not an allocation cap: Venus allocations are
    /// asynchronous, so rejecting them here would kill the guest context, not return OOM.
    /// A user-set VM size gets RAM minus VM RAM minus the host reserve; the automatic one also fits
    /// the memory available at boot (autoSizes).
    static func gpuBudgetMiB(memMiB: Int, auto: Bool, host: Host = .current) -> Int {
        auto ? autoSizes(host).gpu : ramGPUBudgetMiB(memMiB: memMiB, host: host)
    }

    private static func ramGPUBudgetMiB(memMiB: Int, host: Host) -> Int {
        let remaining = Int(host.memBytes >> 20) - memMiB - hostReserveMiB(host)
        return min(16384, max(256, remaining / 256 * 256))
    }

    static func autoMemMiB(_ host: Host) -> Int { autoSizes(host).mem }

    /// Half the Mac's RAM, rounded to whole GiB, 4...16 GiB: 8 GB Mac → 4 GiB, 16 → 8, 32 and up → 16.
    /// The other half stays with macOS and the GPU (MoltenVK device memory, Metal heaps, the
    /// virtio-gpu blobs the guest maps). When guest RAM, the GPU budget and headroomMiB (the VM process
    /// itself, gvproxy, macOS) do not fit in the memory available at boot, the GPU budget shrinks first
    /// (not below 2 GiB), then guest RAM (not below 8 GiB): a 48 GB Mac with 16 + 16 GiB and other apps
    /// open swapped 51 GB and macOS killed the VM. Guest RAM is a hard limit, the budget only steers
    /// texture quality: a 10 GiB guest swapped 2.5 GiB in a Bodycam match.
    static func autoSizes(_ host: Host) -> (mem: Int, gpu: Int) {
        let halfMiB = Int(host.memBytes >> 21)
        let rounded = (halfMiB + 512) / 1024 * 1024
        let mem = min(maxAutoMemMiB, max(minAutoMemMiB, rounded))
        let gpu = ramGPUBudgetMiB(memMiB: mem, host: host)
        guard let avail = host.availMiB, mem + gpu + headroomMiB(host) > avail else { return (mem, gpu) }
        let room = max(0, avail - headroomMiB(host))
        let fitGPU = max(min(gpu, 2048), min(gpu, (room - mem) / 256 * 256))
        return (max(min(mem, 8192), min(mem, (room - fitGPU) / 1024 * 1024)), fitGPU)
    }

    /// One vCPU per performance core, 2...8: M1 / M2 / M3 / M4 (4 P) → 4, Pro chips → 6-8, Max → 8.
    /// The vCPU threads run at user-interactive QoS (libkrun patch 0013), so macOS keeps them on
    /// P-cores; more vCPUs than P-cores puts guest threads on efficiency cores (a fraction of the
    /// speed), where a lock holder or a FEX JIT thread stalls the vCPUs waiting for it. Past 8,
    /// Steam, Proton and FEX gain little, while the host's own frame-path threads (virglrenderer
    /// rings, MoltenVK pipeline compiles, the renderer) need cores too.
    static func autoCPUs(_ host: Host) -> Int {
        min(maxAutoCPUs, max(2, min(minAutoCPUs, host.cores), host.fastCores))
    }

    /// Settings > Advanced: why a custom memory size is risky on this Mac, or nil.
    static func memWarning(memMiB: Int, host: Host) -> String? {
        let gpu = ramGPUBudgetMiB(memMiB: memMiB, host: host)
        let reserve = hostReserveMiB(host)
        guard memMiB + gpu + reserve > Int(host.memBytes >> 20) || gpu < 2048 else { return nil }
        return String(localized: "\(memMiB) MiB VM RAM + \(gpu) MiB GPU budget + \(reserve) MiB reserved for macOS on this \(host.memGiB) GB Mac. Too little GPU memory remains: lower VM memory or graphics settings to avoid swapping, out-of-memory errors or the VM being killed.")
    }

    /// Settings > Advanced: why a custom vCPU count is risky on this Mac, or nil.
    static func cpuWarning(cpus: Int, host: Host) -> String? {
        guard let p = host.perfCores, cpus > p else { return nil }
        return String(localized: "More than this Mac's \(p) performance cores. The extra vCPUs run on efficiency cores, which slows the guest down and leaves fewer cores for the Mac's GPU work.")
    }

    /// Boot log: the size and where it came from.
    static func describe(cpus: Int, cpusSource: Source, memMiB: Int, memSource: Source,
                         gpuMiB: Int? = nil, host: Host = .current) -> String {
        let cores = host.perfCores.map { "\($0) performance cores of \(host.cores)" } ?? "\(host.cores) cores"
        let cpuWhy = cpusSource == .auto ? "automatic: \(cores), \(minAutoCPUs)-\(maxAutoCPUs)" : cpusSource.rawValue
        let memWhy = memSource == .auto
            ? "automatic: half of \(host.memGiB) GB RAM, \(minAutoMemMiB / 1024)-\(maxAutoMemMiB / 1024) GB"
                + (autoSizes(host) != autoSizes(host.idle) ? ", lowered: other apps use memory" : "")
            : memSource.rawValue
        return "\(cpus) vCPUs (\(cpuWhy)), \(memMiB) MiB memory (\(memWhy)), "
            + "\(gpuMiB ?? gpuBudgetMiB(memMiB: memMiB, auto: memSource == .auto, host: host)) MiB GPU budget, \(hostReserveMiB(host)) MiB host reserve"
            + (host.availMiB.map { ", \($0) MiB available at boot" } ?? "")
    }

    /// Settings self-test: the formulas on simulated Macs, and the warnings.
    static func selfCheck() -> [String] {
        let gib: UInt64 = 1 << 30
        var failures: [String] = []
        func host(_ gb: UInt64, _ p: Int?, _ cores: Int) -> Host { Host(memBytes: gb * gib, perfCores: p, cores: cores) }
        let mem: [(UInt64, Int)] = [(8, 4096), (16, 8192), (18, 9216), (24, 12288), (32, 16384), (36, 16384),
                                    (64, 16384), (128, 16384)]
        for (gb, want) in mem where autoMemMiB(host(gb, 4, 8)) != want {
            failures.append("sizing: \(gb) GB → \(autoMemMiB(host(gb, 4, 8))) MiB, want \(want)")
        }
        // (P, all cores, want): M1 4+4, M4 4+6, M2 Pro 6+4, M1 Pro 8+2, M3 Max 12+4 (14-core: 10+4), 1 P,
        // 2 fast of 12 (STEAMAC-2K), 2 cores, no perflevel sysctl.
        let cpus: [(Int?, Int, Int)] = [(4, 8, 4), (4, 10, 4), (6, 10, 6), (8, 10, 8), (12, 16, 8), (10, 14, 8), (1, 4, 4),
                                        (2, 12, 4), (1, 2, 2), (nil, 8, 8), (nil, 1, 2)]
        for (p, n, want) in cpus where autoCPUs(host(16, p, n)) != want {
            failures.append("sizing: \(p.map(String.init) ?? "-")P/\(n) cores → \(autoCPUs(host(16, p, n))) vCPUs, want \(want)")
        }
        // --mem is checked on a first boot too (needsDisk), with a kernel, so the other checks cannot mask it.
        func rejected(_ flag: String, _ value: String, needsDisk: Bool) -> Bool {
            guard var o = try? Options.parse(["steamac-vm", flag, value]) else { return false }
            o.kernel = "/dev/null"
            o.needsDisk = needsDisk
            return (try? o.validate()) == nil
        }
        func memRejected(_ mib: Int, needsDisk: Bool) -> Bool { rejected("--mem", String(mib), needsDisk: needsDisk) }
        // --cpus 0 on a first boot: same early return as --mem (validate skipped the CPU check).
        if !rejected("--cpus", "0", needsDisk: true) { failures.append("sizing: --cpus 0 accepted on a first boot") }
        if !rejected("--cpus", "0", needsDisk: false) { failures.append("sizing: --cpus 0 accepted") }
        if rejected("--cpus", "1", needsDisk: false) { failures.append("sizing: --cpus 1 rejected") }
        if rejected("--cpus", "255", needsDisk: false) { failures.append("sizing: --cpus 255 rejected") }
        if !rejected("--cpus", "256", needsDisk: false) { failures.append("sizing: --cpus 256 accepted") }
        if !memRejected(0, needsDisk: true) { failures.append("sizing: --mem 0 accepted on a first boot") }
        if !memRejected(0, needsDisk: false) { failures.append("sizing: --mem 0 accepted") }
        if !memRejected(minMemMiB - 1, needsDisk: false) { failures.append("sizing: --mem \(minMemMiB - 1) accepted") }
        if memRejected(minMemMiB, needsDisk: false) { failures.append("sizing: --mem \(minMemMiB) rejected") }
        let air = host(8, 4, 8)
        if memWarning(memMiB: 4096, host: air) == nil { failures.append("sizing: 1 GiB GPU budget on an 8 GB Mac not warned") }
        if memWarning(memMiB: 5120, host: air) == nil { failures.append("sizing: 5 GB on an 8 GB Mac not warned") }
        if memWarning(memMiB: 16384, host: host(36, 10, 14)) != nil { failures.append("sizing: 16 GB on a 36 GB Mac warned") }
        let budgets: [(UInt64, Int, Int)] = [(8, 4096, 1024), (16, 8192, 4096), (16, 9216, 3072),
                                            (16, 12288, 256), (32, 16384, 8192), (64, 16384, 16384),
                                            (8, 16384, 256)]
        for (gb, vm, want) in budgets where gpuBudgetMiB(memMiB: vm, auto: false, host: host(gb, 4, 8)) != want {
            failures.append("sizing: GPU budget \(gb) GB / \(vm) MiB VM, want \(want)")
        }
        // (GB, available GiB, want VM MiB, want GPU MiB, fits): enough available keeps the idle sizes; the 48 GB
        // Mac with Docker, Zoom and browsers open (about 26 GiB available) no longer gets 16 + 16 GiB. The GPU
        // budget shrinks first and keeps the 16 GiB VM. Rows that fit leave headroomMiB of the available memory;
        // the others get the floors (8 GiB VM, 2 GiB GPU, or the idle sizes when smaller).
        let busy: [(UInt64, UInt64, Int, Int, Bool)] = [
            (48, 40, 16384, 16384, true), (48, 32, 16384, 13312, true), (48, 26, 16384, 7168, true),
            (48, 20, 15360, 2048, true), (48, 12, 8192, 2048, false), (16, 12, 8192, 2048, true),
            (16, 8, 8192, 2048, false), (8, 7, 4096, 1024, true),
            (16, 4, 8192, 2048, false), (8, 1, 4096, 1024, false)]
        for (gb, avail, wantMem, wantGPU, fits) in busy {
            var h = host(gb, 4, 8)
            h.availBytes = avail * gib
            let mem = autoMemMiB(h), gpu = gpuBudgetMiB(memMiB: mem, auto: true, host: h)
            if mem != wantMem || gpu != wantGPU {
                failures.append("sizing: \(gb) GB with \(avail) GiB available → \(mem) + \(gpu) MiB, want \(wantMem) + \(wantGPU)")
            }
            if fits && mem + gpu + headroomMiB(h) > Int(avail) * 1024 {
                failures.append("sizing: \(gb) GB with \(avail) GiB available → \(mem) + \(gpu) + \(headroomMiB(h)) MiB headroom does not fit")
            }
        }
        // A user-set VM size keeps the RAM rule on a busy Mac, also when it equals the shrunk automatic size:
        // custom 16 and 8 GiB on a 32 GB Mac with 8 GiB available.
        var busy32 = host(32, 4, 8)
        busy32.availBytes = 8 * gib
        for (vm, want) in [(16384, 8192), (8192, 16384)] where gpuBudgetMiB(memMiB: vm, auto: false, host: busy32) != want {
            failures.append("sizing: custom \(vm) MiB on a busy 32 GB Mac → \(gpuBudgetMiB(memMiB: vm, auto: false, host: busy32)) MiB GPU budget, want \(want)")
        }
        if cpuWarning(cpus: 4, host: air) != nil { failures.append("sizing: 4 vCPUs on 4 P-cores warned") }
        if cpuWarning(cpus: 8, host: air) == nil { failures.append("sizing: 8 vCPUs on 4 P-cores not warned") }
        let here = Host.current
        log("selftest-settings: sizing check: \(failures.isEmpty ? "ok" : failures.joined(separator: "; ")) "
            + "(this Mac: \(here.memGiB) GB, \(here.perfCores.map(String.init) ?? "?") P of \(here.cores) cores → "
            + "\(autoMemMiB(here)) MiB, \(autoCPUs(here)) vCPUs, \(here.availMiB.map(String.init) ?? "?") MiB available)")
        return failures
    }

    /// kern.memorystatus_level: the "free percentage" of memory_pressure. It counts memory macOS can
    /// compress or page out without pressure, unlike vm_stat's free pages.
    private static func availableMemory() -> UInt64? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return UInt64(max(0, min(100, level))) * ProcessInfo.processInfo.physicalMemory / 100
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value > 0 ? Int(value) : nil
    }

    /// Sum of the non-efficiency performance levels. Without level names, every level but the
    /// last (the slowest) counts.
    private static func fastCoreCount() -> Int? {
        guard let levels = sysctlInt("hw.nperflevels"), levels > 0 else { return nil }
        var fast = 0
        for i in 0..<levels {
            guard let cores = sysctlInt("hw.perflevel\(i).physicalcpu") else { return nil }
            let name = sysctlString("hw.perflevel\(i).name")
            let efficiency = name.map { $0 == "Efficiency" } ?? (levels > 1 && i == levels - 1)
            if !efficiency { fast += cores }
        }
        return fast > 0 ? fast : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
