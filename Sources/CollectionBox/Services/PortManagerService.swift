import Foundation
import AppKit
import Darwin

@MainActor
public final class PortManagerService: ObservableObject {
    public static let shared = PortManagerService()

    private static let favoriteKeysDefaultsKey = "Pinner.favoritePortKeys"

    @Published public private(set) var processes: [PortProcessInfo] = []
    @Published public private(set) var stats = PortSummaryStats()
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastUpdated: Date? = nil
    @Published public var searchText: String = ""
    @Published public var selectedFilter: ProcessFilterCategory = .all

    private var refreshTimer: Timer?
    private var favoriteKeys: Set<String>

    public init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.favoriteKeysDefaultsKey) {
            self.favoriteKeys = Set(saved)
        } else {
            self.favoriteKeys = []
        }
    }

    // MARK: - Monitoring Lifecycle

    public func startMonitoring(interval: TimeInterval = 2.5) {
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
    }

    // MARK: - Process Scanning & Aggregation

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) { () -> ([PortProcessInfo], PortSummaryStats) in
            return Self.scanPortsAndProcessesSync()
        }.value

        // Re-apply favorite state based on stored keys
        let updatedProcesses = result.0.map { proc -> PortProcessInfo in
            var p = proc
            p.isFavorite = self.isFavorite(process: p)
            return p
        }

        self.processes = sortProcesses(updatedProcesses)
        self.stats = result.1
        self.lastUpdated = Date()
    }

    private func sortProcesses(_ list: [PortProcessInfo]) -> [PortProcessInfo] {
        return list.sorted { a, b in
            if a.category != b.category {
                if a.category == .docker { return true }
                if b.category == .docker { return false }
                if a.category == .devServer { return true }
                if b.category == .devServer { return false }
                if a.category == .userApp { return true }
                if b.category == .userApp { return false }
            }
            let aMinPort = a.ports.first ?? Int.max
            let bMinPort = b.ports.first ?? Int.max
            if aMinPort != bMinPort {
                return aMinPort < bMinPort
            }
            return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
    }

    // MARK: - Favorites Management

    public func toggleFavorite(process: PortProcessInfo) {
        let key = favoriteKey(for: process)
        if favoriteKeys.contains(key) {
            favoriteKeys.remove(key)
        } else {
            favoriteKeys.insert(key)
        }
        UserDefaults.standard.set(Array(favoriteKeys), forKey: Self.favoriteKeysDefaultsKey)

        // Update in-memory state
        self.processes = sortProcesses(processes.map { proc in
            var p = proc
            p.isFavorite = self.isFavorite(process: p)
            return p
        })
    }

    public func isFavorite(process: PortProcessInfo) -> Bool {
        return favoriteKeys.contains(favoriteKey(for: process))
    }

    private func favoriteKey(for process: PortProcessInfo) -> String {
        let firstPort = process.ports.first.map(String.init) ?? "*"
        return "\(process.displayName):\(firstPort)"
    }

    // MARK: - Process Termination & Escalation

    @discardableResult
    public func terminateProcess(process: PortProcessInfo, force: Bool = true) async -> Result<Void, Error> {
        // If it's a Docker container, prefer docker stop / docker kill to avoid killing the entire VM/daemon
        if let container = process.containerName, !container.isEmpty {
            return await stopDockerContainer(name: container, force: force)
        }
        return await terminateProcess(pid: process.pid, isRoot: process.isRoot, force: force)
    }

    @discardableResult
    public func terminateProcess(pid: pid_t, isRoot: Bool, force: Bool = true) async -> Result<Void, Error> {
        if isRoot {
            return await terminateWithAdministratorPrivileges(pid: pid)
        } else {
            let sig = force ? SIGKILL : SIGTERM
            let res = Darwin.kill(pid, sig)
            if res == 0 {
                Haptics.success()
                await refresh()
                return .success(())
            } else {
                let err = errno
                if err == EPERM {
                    // Permission denied: escalate with administrator privileges via AppleScript
                    return await terminateWithAdministratorPrivileges(pid: pid)
                } else {
                    Haptics.levelChange()
                    let error = NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(err),
                        userInfo: [NSLocalizedDescriptionKey: "无法终止进程 PID \(pid) (错误码: \(err))"]
                    )
                    return .failure(error)
                }
            }
        }
    }

    private func stopDockerContainer(name: String, force: Bool) async -> Result<Void, Error> {
        return await Task.detached(priority: .userInitiated) { [weak self] () -> Result<Void, Error> in
            let possiblePaths = [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                NSHomeDirectory() + "/.orbstack/bin/docker",
                "/usr/bin/docker"
            ]
            guard let dockerPath = possiblePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                let err = NSError(domain: "DockerError", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到 docker 命令行工具"])
                return .failure(err)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: dockerPath)
            proc.arguments = [force ? "kill" : "stop", name]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    await MainActor.run {
                        Haptics.success()
                        Task { [weak self] in
                            await self?.refresh()
                        }
                    }
                    return .success(())
                } else {
                    let err = NSError(
                        domain: "DockerError",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "停止 Docker 容器 \(name) 失败"]
                    )
                    return .failure(err)
                }
            } catch {
                return .failure(error)
            }
        }.value
    }

    private func terminateWithAdministratorPrivileges(pid: pid_t) async -> Result<Void, Error> {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let scriptSource = "do shell script \"kill -9 \(pid)\" with administrator privileges"
                var errorDict: NSDictionary?
                if let script = NSAppleScript(source: scriptSource) {
                    _ = script.executeAndReturnError(&errorDict)
                    if let errorDict = errorDict {
                        let errMsg = (errorDict[NSAppleScript.errorMessage] as? String) ?? "管理员授权失败"
                        let errCode = (errorDict[NSAppleScript.errorNumber] as? Int) ?? -1
                        let error = NSError(domain: "AppleScriptError", code: errCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
                        DispatchQueue.main.async {
                            Haptics.levelChange()
                        }
                        continuation.resume(returning: .failure(error))
                        return
                    }
                }
                DispatchQueue.main.async {
                    Haptics.success()
                    Task { [weak self] in
                        await self?.refresh()
                    }
                }
                continuation.resume(returning: .success(()))
            }
        }
    }

    public func revealInFinder(path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    public func fetchCommandLine(for pid: pid_t) async -> String {
        return await Task.detached(priority: .utility) {
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", "\(pid)", "-o", "command="]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return output
            } catch {
                return ""
            }
        }.value
    }

    // MARK: - Synchronous Worker: Lsof, Docker & Ps Parsing

    struct DockerContainerPortInfo {
        let containerName: String
        let imageName: String
    }

    nonisolated private static func fetchDockerPortMappings() -> [Int: DockerContainerPortInfo] {
        let possiblePaths = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            NSHomeDirectory() + "/.orbstack/bin/docker",
            "/usr/bin/docker"
        ]
        guard let dockerPath = possiblePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return [:]
        }

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: dockerPath)
        proc.arguments = ["ps", "--format", "{{.Ports}}\t{{.Names}}\t{{.Image}}"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var map: [Int: DockerContainerPortInfo] = [:]
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { return }
            let portsStr = parts[0]
            let containerName = parts[1]
            let imageName = parts.count >= 3 ? parts[2] : ""

            let container = DockerContainerPortInfo(containerName: containerName, imageName: imageName)

            // Extract host ports e.g. "0.0.0.0:8000->8000/tcp, [::]:8000->8000/tcp"
            for segment in portsStr.components(separatedBy: ",") {
                let seg = segment.trimmingCharacters(in: .whitespaces)
                if let arrowRange = seg.range(of: "->") {
                    let hostPart = String(seg[..<arrowRange.lowerBound])
                    if let colonIdx = hostPart.lastIndex(of: ":") {
                        let portStr = String(hostPart[hostPart.index(after: colonIdx)...])
                        if let port = Int(portStr) {
                            map[port] = container
                        }
                    }
                }
            }
        }
        return map
    }

    nonisolated private static func scanPortsAndProcessesSync() -> ([PortProcessInfo], PortSummaryStats) {
        // 1. Run lsof -n -P -iTCP -sTCP:LISTEN -F pcuPn
        let lsofPipe = Pipe()
        let lsofProc = Process()
        lsofProc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProc.arguments = ["-n", "-P", "-iTCP", "-sTCP:LISTEN", "-F", "pcuPn"]
        lsofProc.standardOutput = lsofPipe
        lsofProc.standardError = FileHandle.nullDevice

        do {
            try lsofProc.run()
        } catch {
            return ([], PortSummaryStats())
        }

        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        lsofProc.waitUntilExit()

        guard let output = String(data: lsofData, encoding: .utf8) else {
            return ([], PortSummaryStats())
        }

        // Intermediate parsing storage
        struct RawProcessEntry {
            var pid: pid_t
            var command: String
            var user: String
            var ports: Set<Int>
        }

        var processMap: [pid_t: RawProcessEntry] = [:]
        var currentPid: pid_t? = nil
        var exposedPorts: Set<Int> = []

        output.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            let prefix = line.first!
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                if let p = pid_t(value) {
                    currentPid = p
                    if processMap[p] == nil {
                        processMap[p] = RawProcessEntry(pid: p, command: "", user: "", ports: [])
                    }
                }
            case "c":
                if let p = currentPid {
                    processMap[p]?.command = value
                }
            case "u":
                if let p = currentPid {
                    processMap[p]?.user = value
                }
            case "n":
                // Parse port from e.g. *:57049 or 127.0.0.1:3000 or [::1]:8080 or 0.0.0.0:8000
                if let colonIdx = value.lastIndex(of: ":") {
                    let portStr = String(value[value.index(after: colonIdx)...])
                    if let portNum = Int(portStr), let p = currentPid {
                        processMap[p]?.ports.insert(portNum)
                        let host = String(value[..<colonIdx])
                        if host == "*" || host == "0.0.0.0" || host == "[::]" || host == "::" || (!host.isEmpty && host != "127.0.0.1" && host != "localhost" && host != "[::1]" && host != "::1") {
                            exposedPorts.insert(portNum)
                        }
                    }
                }
            default:
                break
            }
        }

        guard !processMap.isEmpty else {
            return ([], PortSummaryStats())
        }

        // 2. Query ps -p <pids> -o pid=,%cpu=,rss=,user=
        let pids = Array(processMap.keys)
        let pidArg = pids.map(String.init).joined(separator: ",")

        let psPipe = Pipe()
        let psProc = Process()
        psProc.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProc.arguments = ["-p", pidArg, "-o", "pid=,%cpu=,rss=,user="]
        psProc.standardOutput = psPipe
        psProc.standardError = FileHandle.nullDevice

        var psInfoMap: [pid_t: (cpu: Double, rssBytes: Int64, user: String)] = [:]

        if let _ = try? psProc.run() {
            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            psProc.waitUntilExit()
            if let psOutput = String(data: psData, encoding: .utf8) {
                psOutput.enumerateLines { line, _ in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    guard tokens.count >= 4,
                          let pid = pid_t(tokens[0]),
                          let cpu = Double(tokens[1]),
                          let rssKB = Int64(tokens[2]) else { return }
                    let user = tokens[3]
                    psInfoMap[pid] = (cpu: cpu, rssBytes: rssKB * 1024, user: user)
                }
            }
        }

        // 3. Query Docker container port mappings
        let dockerPortMap = fetchDockerPortMappings()

        // 4. Assemble PortProcessInfo records
        var resultList: [PortProcessInfo] = []
        var totalPorts = 0
        var totalMemory: Int64 = 0
        var devCount = 0
        var dockerCount = 0
        var rootCount = 0

        for (pid, raw) in processMap {
            let sortedPorts = Array(raw.ports).sorted()
            totalPorts += sortedPorts.count

            let ps = psInfoMap[pid]
            let cpu = ps?.cpu ?? 0.0
            let memory = ps?.rssBytes ?? 0
            let user = ps?.user ?? (raw.user.isEmpty ? "unknown" : raw.user)
            let isRoot = (user == "root" || user == "0")

            if isRoot { rootCount += 1 }
            totalMemory += memory

            let fullPath = getProcessFullPath(pid: pid)
            let cmdLower = raw.command.lowercased()
            let isDockerDaemon = cmdLower.contains("orbstack") || cmdLower.contains("docker") || cmdLower.contains("vpnkit")

            // Check if any ports belong to Docker containers
            var dockerPortsByContainer: [String: (info: DockerContainerPortInfo, ports: [Int])] = [:]
            var remainingPorts: [Int] = []

            for port in sortedPorts {
                if let containerInfo = dockerPortMap[port] {
                    if dockerPortsByContainer[containerInfo.containerName] != nil {
                        dockerPortsByContainer[containerInfo.containerName]?.ports.append(port)
                    } else {
                        dockerPortsByContainer[containerInfo.containerName] = (containerInfo, [port])
                    }
                } else {
                    remainingPorts.append(port)
                }
            }

            // Emit distinct entries for each Docker container
            for (_, containerTuple) in dockerPortsByContainer {
                dockerCount += 1
                let cExposedPorts = containerTuple.ports.filter { exposedPorts.contains($0) }
                let info = PortProcessInfo(
                    pid: pid,
                    command: containerTuple.info.containerName,
                    fullPath: fullPath,
                    commandLine: "Docker: \(containerTuple.info.imageName)",
                    user: user,
                    isRoot: isRoot,
                    ports: containerTuple.ports,
                    protocolType: "TCP",
                    cpuPercent: cpu,
                    memoryBytes: memory,
                    category: .docker,
                    isFavorite: false,
                    isExposed: !cExposedPorts.isEmpty,
                    exposedPorts: cExposedPorts,
                    containerName: containerTuple.info.containerName,
                    containerImage: containerTuple.info.imageName
                )
                resultList.append(info)
            }

            // Emit entry for remaining non-container ports of this process
            if !remainingPorts.isEmpty {
                let category: ProcessCategory
                if isDockerDaemon {
                    category = .docker
                    dockerCount += 1
                } else {
                    category = classifyProcess(command: raw.command, fullPath: fullPath, user: user)
                    if category == .devServer { devCount += 1 }
                }

                let rExposedPorts = remainingPorts.filter { exposedPorts.contains($0) }
                let info = PortProcessInfo(
                    pid: pid,
                    command: raw.command,
                    fullPath: fullPath,
                    commandLine: "",
                    user: user,
                    isRoot: isRoot,
                    ports: remainingPorts,
                    protocolType: "TCP",
                    cpuPercent: cpu,
                    memoryBytes: memory,
                    category: category,
                    isFavorite: false,
                    isExposed: !rExposedPorts.isEmpty,
                    exposedPorts: rExposedPorts
                )
                resultList.append(info)
            }
        }

        var totalCpu: Double = 0.0
        for (_, ps) in psInfoMap {
            totalCpu += ps.cpu
        }

        let summary = PortSummaryStats(
            activePortCount: totalPorts,
            totalMemoryBytes: totalMemory,
            devServerCount: devCount,
            dockerCount: dockerCount,
            rootProcessCount: rootCount,
            totalCpuPercent: totalCpu,
            exposedPortCount: exposedPorts.count
        )

        return (resultList, summary)
    }

    // MARK: - Native C API for Executable Path

    nonisolated public static func getProcessFullPath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if len > 0 {
            return String(cString: buffer)
        }
        return ""
    }

    // MARK: - Process Classifier

    nonisolated public static func classifyProcess(command: String, fullPath: String, user: String) -> ProcessCategory {
        let cmdLower = command.lowercased()
        let pathLower = fullPath.lowercased()

        // 1. Docker check
        if cmdLower.contains("docker") || cmdLower.contains("orbstack") || cmdLower.contains("vpnkit") {
            return .docker
        }

        // 2. System services check
        let systemPrefixes = ["/system/", "/usr/libexec/", "/usr/sbin/", "/system/library/"]
        let isSystemPath = systemPrefixes.contains { pathLower.hasPrefix($0) }
        let systemCommands = [
            "rapportd", "controlcenter", "mdnsresponder", "launchd", "cupsd",
            "configd", "loginwindow", "sharingd", "identityservicesd", "apsd",
            "trustd", "opendirectoryd", "systemstatusd", "bluetoothd", "airplayxpchelper"
        ]
        if isSystemPath || systemCommands.contains(cmdLower) || user.hasPrefix("_") {
            return .systemDaemon
        }

        // 3. Dev server keywords
        let devKeywords = [
            "node", "python", "python3", "vite", "next", "react", "vue", "nuxt",
            "deno", "bun", "go", "ruby", "java", "rust", "cargo", "redis",
            "postgres", "mysql", "nginx", "caddy", "flask", "django",
            "uvicorn", "gunicorn", "fastapi", "spring", "gradle", "rails", "php",
            "artisan", "cloudflared", "ngrok", "ollama", "vllm", "webpack", "esbuild",
            "turbo", "mongod", "mongos", "etcd", "traefik", "minio", "sqlite3"
        ]
        if devKeywords.contains(where: { cmdLower.contains($0) || pathLower.contains($0) }) {
            return .devServer
        }

        // 4. Defaults to standard user application
        return .userApp
    }
}
