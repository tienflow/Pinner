import Foundation
import AppKit
import Darwin

@MainActor
public final class ProcessManagerService: ObservableObject {
    public static let shared = ProcessManagerService()

    @Published public private(set) var processes: [ManagedProcessEntry] = []
    @Published public private(set) var systemPressure: SystemPressureInfo = SystemPressureInfo()
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdated: Date? = nil

    @Published public var sortField: ProcessSortField = .cpu
    @Published public var sortAscending: Bool = false
    @Published public var filterOption: ProcessFilterOption = .highLoad
    @Published public var searchText: String = ""

    private var refreshTimer: Timer?
    private var lastCpuTicks: host_cpu_load_info_data_t? = nil
    private var lastProcessSamples: [pid_t: (cpuTimeNano: UInt64, wakeups: UInt64, timestamp: TimeInterval)] = [:]

    public init() {}

    // MARK: - Monitoring Lifecycle

    public func startMonitoring(interval: TimeInterval = 2.0) {
        stopMonitoring()
        Task {
            await refresh()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    public func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        lastProcessSamples.removeAll()
        lastCpuTicks = nil
    }

    // MARK: - Data Refresh

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let previousTicks = self.lastCpuTicks
        let previousSamples = self.lastProcessSamples
        let nowUptime = ProcessInfo.processInfo.systemUptime

        let result = await Task.detached(priority: .userInitiated) { () -> (SystemPressureInfo, host_cpu_load_info_data_t?, [ManagedProcessEntry], [pid_t: (cpuTimeNano: UInt64, wakeups: UInt64, timestamp: TimeInterval)]) in
            return Self.collectMetricsSync(
                previousTicks: previousTicks,
                previousSamples: previousSamples,
                nowUptime: nowUptime
            )
        }.value

        self.systemPressure = result.0
        self.lastCpuTicks = result.1
        self.lastProcessSamples = result.3
        self.processes = result.2
        self.lastUpdated = Date()
    }

    // MARK: - Process Actions

    @discardableResult
    public func toggleSuspend(process: ManagedProcessEntry) -> Bool {
        if process.isSuspended {
            let ok = kill(process.pid, SIGCONT) == 0
            if ok {
                updateProcessSuspension(pid: process.pid, isSuspended: false)
            }
            return ok
        } else {
            let ok = kill(process.pid, SIGSTOP) == 0
            if ok {
                updateProcessSuspension(pid: process.pid, isSuspended: true)
            }
            return ok
        }
    }

    private func updateProcessSuspension(pid: pid_t, isSuspended: Bool) {
        if let idx = processes.firstIndex(where: { $0.pid == pid }) {
            var updated = processes[idx]
            updated.isSuspended = isSuspended
            processes[idx] = updated
        }
    }

    @discardableResult
    public func terminateProcess(process: ManagedProcessEntry, force: Bool = true) async -> Result<Void, Error> {
        let sig = force ? SIGKILL : SIGTERM
        if kill(process.pid, sig) == 0 {
            processes.removeAll { $0.pid == process.pid }
            return .success(())
        }

        let err = errno
        if err == EPERM {
            // Permission denied -> attempt escalation via AppleScript
            return await escalateKill(pid: process.pid, force: force)
        }

        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
            NSLocalizedDescriptionKey: "无法终止进程 PID \(process.pid): \(String(cString: strerror(err)))"
        ])
        return .failure(error)
    }

    private func escalateKill(pid: pid_t, force: Bool) async -> Result<Void, Error> {
        let flag = force ? "-9" : "-15"
        let scriptSource = "do shell script \"kill \(flag) \(pid)\" with administrator privileges"
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorDict: NSDictionary?
                if let script = NSAppleScript(source: scriptSource) {
                    script.executeAndReturnError(&errorDict)
                    if let err = errorDict {
                        let msg = err[NSAppleScript.errorMessage] as? String ?? "管理员授权失败"
                        continuation.resume(returning: .failure(NSError(domain: "Pinner.ProcessManager", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])))
                    } else {
                        Task { @MainActor in
                            self.processes.removeAll { $0.pid == pid }
                        }
                        continuation.resume(returning: .success(()))
                    }
                } else {
                    continuation.resume(returning: .failure(NSError(domain: "Pinner.ProcessManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "创建提权脚本失败"])))
                }
            }
        }
    }

    // MARK: - Synchronous Collection Engine (Background)

    private nonisolated static func collectMetricsSync(
        previousTicks: host_cpu_load_info_data_t?,
        previousSamples: [pid_t: (cpuTimeNano: UInt64, wakeups: UInt64, timestamp: TimeInterval)],
        nowUptime: TimeInterval
    ) -> (SystemPressureInfo, host_cpu_load_info_data_t?, [ManagedProcessEntry], [pid_t: (cpuTimeNano: UInt64, wakeups: UInt64, timestamp: TimeInterval)]) {
        // 1. Host CPU Ticks
        let currentTicks = sampleCPUTicks()
        var userPercent: Double = 0.0
        var sysPercent: Double = 0.0
        var totalCpuPercent: Double = 0.0

        if let cur = currentTicks, let prev = previousTicks {
            let userDiff = Double(cur.cpu_ticks.0 - prev.cpu_ticks.0)
            let sysDiff = Double(cur.cpu_ticks.1 - prev.cpu_ticks.1)
            let idleDiff = Double(cur.cpu_ticks.2 - prev.cpu_ticks.2)
            let niceDiff = Double(cur.cpu_ticks.3 - prev.cpu_ticks.3)
            let totalDiff = userDiff + sysDiff + idleDiff + niceDiff

            if totalDiff > 0 {
                userPercent = (userDiff / totalDiff) * 100.0
                sysPercent = (sysDiff / totalDiff) * 100.0
                totalCpuPercent = ((userDiff + sysDiff + niceDiff) / totalDiff) * 100.0
            }
        }

        // 2. Memory & Swap
        let (usedMem, totalMem, pressureLevel, swapUsed, swapTotal) = sampleMemoryAndPressure()

        let pressureInfo = SystemPressureInfo(
            cpuUserPercent: max(0.0, min(100.0, userPercent)),
            cpuSystemPercent: max(0.0, min(100.0, sysPercent)),
            cpuTotalPercent: max(0.0, min(100.0, totalCpuPercent)),
            logicalCores: ProcessInfo.processInfo.processorCount,
            memoryPressure: pressureLevel,
            physicalMemoryUsedBytes: usedMem,
            physicalMemoryTotalBytes: totalMem,
            swapUsedBytes: swapUsed,
            swapTotalBytes: swapTotal
        )

        // 3. Process Listing via Darwin proc_listpids
        let pidsBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidsBytes > 0 else {
            return (pressureInfo, currentTicks, [], [:])
        }

        let pidCount = Int(pidsBytes) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: pidCount)
        proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, pidsBytes)

        var newSamples: [pid_t: (cpuTimeNano: UInt64, wakeups: UInt64, timestamp: TimeInterval)] = [:]
        var entries: [ManagedProcessEntry] = []
        entries.reserveCapacity(pidCount)

        let selfPid = getpid()

        for pid in pids where pid > 0 && pid != selfPid {
            var taskInfo = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard size == MemoryLayout<proc_taskinfo>.size else { continue }

            let totalCpuNano = taskInfo.pti_total_user + taskInfo.pti_total_system

            // Wakeups & Darwin rusage for Energy Impact
            var totalWakeups: UInt64 = UInt64(taskInfo.pti_csw)
            var rusage = rusage_info_v6()
            let rusageStatus = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { rusagePtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rusagePtr)
                }
            }
            if rusageStatus == 0 {
                totalWakeups = rusage.ri_pkg_idle_wkups + rusage.ri_interrupt_wkups
            }

            newSamples[pid] = (totalCpuNano, totalWakeups, nowUptime)

            var cpuUsage: Double = 0.0
            var energyImpact: Double = 0.0
            if let prev = previousSamples[pid] {
                let dt = nowUptime - prev.timestamp
                if dt > 0.1 {
                    if totalCpuNano >= prev.cpuTimeNano {
                        let dCpu = Double(totalCpuNano - prev.cpuTimeNano)
                        cpuUsage = (dCpu / 1_000_000_000.0) / dt * 100.0
                    }
                    var wakeupsPerSec: Double = 0.0
                    if totalWakeups >= prev.wakeups {
                        wakeupsPerSec = Double(totalWakeups - prev.wakeups) / dt
                    }
                    // Activity Monitor energy impact heuristic: CPU% + (Wakeups/s * 0.05)
                    energyImpact = max(0.0, cpuUsage + (wakeupsPerSec * 0.05))
                }
            } else {
                energyImpact = max(0.0, cpuUsage)
            }

            let residentMem = taskInfo.pti_resident_size
            // Skip zero-memory zombie / idle background kernels to save allocations
            if residentMem < 2_000_000 && cpuUsage < 0.5 {
                continue
            }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, 256)
            let rawName = String(cString: nameBuffer)
            let name = rawName.isEmpty ? "pid-\(pid)" : rawName

            // Check if process is suspended (SSTOP)
            var bsdInfo = proc_bsdinfo()
            let isSuspended: Bool
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size {
                isSuspended = (bsdInfo.pbi_status == 3) // SSTOP == 3 in sys/proc.h
            } else {
                isSuspended = false
            }

            let category = classifyProcess(name: name)

            // Extract CLI arguments for high load or runtime processes (e.g. node, python)
            var args: String? = nil
            if category == .runtime || category == .devTool || cpuUsage > 5.0 || residentMem > 500_000_000 {
                args = getProcessArguments(pid: pid)
            }

            let isDocker = name.lowercased().contains("docker") || name.lowercased().contains("orbstack")

            var pathBuffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let fullPath = pathLen > 0 ? String(cString: pathBuffer) : ""

            let entry = ManagedProcessEntry(
                pid: pid,
                name: name,
                arguments: args,
                displayName: nil,
                fullPath: fullPath,
                cpuPercent: max(0.0, cpuUsage),
                residentMemoryBytes: residentMem,
                energyImpact: energyImpact,
                isSuspended: isSuspended,
                isDocker: isDocker,
                dockerContainerName: nil,
                category: category
            )
            entries.append(entry)
        }

        return (pressureInfo, currentTicks, entries, newSamples)
    }

    // MARK: - Mach & Darwin Helpers

    private nonisolated static func sampleCPUTicks() -> host_cpu_load_info_data_t? {
        var cpuLoad = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? cpuLoad : nil
    }

    private nonisolated static func sampleMemoryAndPressure() -> (used: UInt64, total: UInt64, pressure: MemoryPressureLevel, swapUsed: UInt64, swapTotal: UInt64) {
        var totalBytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0)

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var usedBytes: UInt64 = 0
        if kr == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            let active = UInt64(vmStats.active_count) * pageSize
            let wire = UInt64(vmStats.wire_count) * pageSize
            let compressed = UInt64(vmStats.compressor_page_count) * pageSize
            usedBytes = active + wire + compressed
        }

        var pressureLevel: MemoryPressureLevel = .normal
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            if level >= 4 {
                pressureLevel = .critical
            } else if level >= 2 {
                pressureLevel = .warning
            } else {
                pressureLevel = .normal
            }
        } else if totalBytes > 0 {
            let ratio = Double(usedBytes) / Double(totalBytes)
            if ratio > 0.90 { pressureLevel = .critical }
            else if ratio > 0.80 { pressureLevel = .warning }
        }

        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = swap.xsu_used
            swapTotal = swap.xsu_total
        }

        return (usedBytes, totalBytes, pressureLevel, swapUsed, swapTotal)
    }

    public nonisolated static func classifyProcess(name: String) -> ManagedProcessCategory {
        let n = name.lowercased()
        if n.contains("docker") || n.contains("orbstack") || n.contains("containerd") {
            return .docker
        }
        if n.contains("xcode") || n.contains("cursor") || n.contains("code") || n.contains("terminal") || n.contains("iterm") || n.contains("simulator") {
            return .devTool
        }
        if n == "node" || n.hasPrefix("python") || n.hasPrefix("swift") || n == "rustc" || n == "cargo" || n == "clang" || n == "java" || n.contains("ollama") || n == "postgres" || n == "redis-server" {
            return .runtime
        }
        if n.hasPrefix("com.apple.") || n.hasSuffix("d") || n.hasPrefix("_") {
            return .system
        }
        return .userApp
    }

    private nonisolated static func getProcessArguments(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 {
            return nil
        }

        var argc: Int32 = 0
        memcpy(&argc, buffer, MemoryLayout<Int32>.size)
        guard argc > 0 else { return nil }

        var i = MemoryLayout<Int32>.size
        // Skip executable path
        while i < size && buffer[i] != 0 { i += 1 }
        // Skip null bytes
        while i < size && buffer[i] == 0 { i += 1 }

        var args: [String] = []
        var currentArg = ""
        var argCount = 0

        while i < size && argCount < argc {
            if buffer[i] == 0 {
                if !currentArg.isEmpty {
                    args.append(currentArg)
                    currentArg = ""
                    argCount += 1
                }
            } else {
                currentArg.append(Character(UnicodeScalar(UInt8(bitPattern: buffer[i]))))
            }
            i += 1
        }
        if !currentArg.isEmpty && argCount < argc {
            args.append(currentArg)
        }

        guard args.count > 1 else { return nil }
        let userArgs = args.dropFirst().filter { !$0.hasPrefix("-") && !$0.isEmpty }
        if let firstInteresting = userArgs.first {
            let lastPart = (firstInteresting as NSString).lastPathComponent
            return lastPart
        }
        let rawArg = args.dropFirst().prefix(2).joined(separator: " ")
        return rawArg.isEmpty ? nil : rawArg
    }
}
