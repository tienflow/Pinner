import Foundation
import AppKit
import CoreWLAN
import Network
import SystemConfiguration
import Darwin

@MainActor
public final class TrafficMonitorService: ObservableObject {
    public static let shared = TrafficMonitorService()

    @Published public private(set) var ledger: TrafficLedger
    @Published public var currentDownloadRate: Double = 0 // bytes/s
    @Published public var currentUploadRate: Double = 0   // bytes/s
    @Published public var currentPeriod: TrafficPeriod = .today {
        didSet {
            selectedHour = nil
        }
    }
    @Published public var selectedNetwork: String = "__all__" {
        didSet {
            selectedHour = nil
        }
    }
    @Published public var currentNetwork: TrafficNetworkContext = .all
    @Published public var isPaused: Bool = false
    @Published public var statusMessage: String = "采集中"
    @Published public var lastSampleTime: Date? = nil
    @Published public var isLoading: Bool = false
    @Published public var searchText: String = ""
    @Published public var sortField: TrafficSortField = .total
    @Published public var sortAscending: Bool = false

    // 24-Hour Hourly Drill-down State
    @Published public var selectedHour: Int? = nil

    // Mobile Hotspot & Expensive Network Awareness
    @Published public private(set) var isHotspotActive: Bool = false
    @Published public private(set) var hotspotName: String? = nil
    @Published public private(set) var isExpensiveNetwork: Bool = false
    @Published public private(set) var isConstrainedNetwork: Bool = false

    /// 本机系统代理端口（仅当代理指向回环地址时非空）
    @Published public private(set) var localProxyPorts: [Int] = []
    public var isLocalProxyActive: Bool { !localProxyPorts.isEmpty }

    // App icons cached by bundle path or app name
    @Published public private(set) var processIcons: [String: NSImage] = [:]

    private var timer: Timer?
    private var inFlight: Bool = false
    /// Start of the in-flight sample, used by the `sample()` watchdog.
    private var inFlightSince: Date?
    private var oldProcesses: [String: TrafficProcessCounter] = [:]
    private var oldLoopback: [String: LoopbackSnapshot] = [:]
    private var oldInterfaces: [String: TrafficBytes] = [:]
    private var oldTime: Date?
    private var lastSaved: Date = .distantPast
    private var lastPrunedDay: String?
    private var appPaths: [String: String] = [:]
    private var pidMapping: [String: (name: String, path: String)] = [:]
    private var activePIDs: [String: pid_t] = [:]

    // Sampling cadence. Whole-machine rates stay at 3 s (sysctl is free), while
    // the expensive `nettop`/`ps` child processes are amortised over a longer
    // window. Process counters are cumulative, so a 15 s diff is just as exact.
    private var lastProcessSampleTime: Date?
    private var lastPSRefreshTime: Date = .distantPast
    private let processSampleInterval: TimeInterval = 15
    private let psRefreshInterval: TimeInterval = 30

    // Physical bytes are read every 3 s for live rates, but the ledger is only
    // written on a process sample so the "unattributed" row (physical − process)
    // compares two counters measured over the same window.
    private var pendingPhysical = TrafficBytes()
    private var pendingWiFi = TrafficBytes()
    private var pendingEthernet = TrafficBytes()
    private var pendingInterval: TimeInterval = 0

    // CoreWLAN queries are synchronous and were previously paid every 3 s.
    private var cachedNetworkContextValue: TrafficNetworkContext?
    private var cachedNetworkContextAt: Date = .distantPast
    private let networkContextTTL: TimeInterval = 30
    private var cachedWiFiInterfaceNames: Set<String> = []
    private var cachedWiFiInterfaceNamesAt: Date = .distantPast
    private let wifiInterfaceTTL: TimeInterval = 60

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.tienyeung.pinner.traffic.pathmonitor", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "com.tienyeung.pinner.traffic.sampling", qos: .utility)
    private let saveQueue = DispatchQueue(label: "com.tienyeung.pinner.traffic.save", qos: .utility)
    private let ledgerFileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pinner", isDirectory: true)
        self.ledgerFileURL = appSupport.appendingPathComponent("traffic_ledger.json")

        if FileManager.default.fileExists(atPath: self.ledgerFileURL.path) {
            do {
                let data = try Data(contentsOf: self.ledgerFileURL)
                self.ledger = try JSONDecoder().decode(TrafficLedger.self, from: data)
            } catch {
                self.ledger = TrafficLedger()
                let backupURL = appSupport.appendingPathComponent("traffic_ledger_corrupt_\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: self.ledgerFileURL, to: backupURL)
                self.statusMessage = "旧历史数据格式异常，已保留备份并重新初始化"
            }
        } else {
            self.ledger = TrafficLedger()
        }

        startPathMonitor()

        // Register wake notification to avoid calculating huge deltas during sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; assumeIsolated keeps the mutation on
            // the main actor without spawning a task per wake.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.oldTime = nil
                // Force the next tick to re-baseline both process counters and the
                // PID→name map; otherwise sleep-time bytes land in one wake delta.
                self.lastProcessSampleTime = nil
                self.lastPSRefreshTime = .distantPast
                self.clearPendingSampleWindow()
                if self.timer != nil {
                    self.sample()
                }
            }
        }
    }

    // MARK: - Filtered Record and Process List

    public var selectedRecord: TrafficDayRecord {
        let keys = TrafficDateKeys.keys(
            period: currentPeriod,
            now: Date(),
            available: Array(ledger.days.keys)
        )
        return ledger.sum(keys: keys, networkName: selectedNetwork == "__all__" ? nil : selectedNetwork)
    }

    public var availableNetworkNames: [String] {
        var names = Set<String>()
        names.insert("全部网络")

        // Include all recorded network histories
        for history in ledger.networks.values {
            if !history.name.isEmpty {
                names.insert(history.name)
            }
        }

        // Always make sure current connected networks are discoverable
        if currentNetwork.identified && !currentNetwork.name.isEmpty {
            names.insert(currentNetwork.name)
        }

        var sortedNames = names.filter { $0 != "全部网络" }.sorted()
        sortedNames.insert("全部网络", at: 0)
        return sortedNames
    }

    public func selectHour(_ hour: Int?) {
        if selectedHour == hour {
            selectedHour = nil
        } else {
            selectedHour = hour
        }
    }

    public var displayProcessItems: [TrafficProcessItem] {
        let record = selectedRecord
        var items: [TrafficProcessItem] = []

        let procSource: [String: TrafficBytes]
        let proxiedSource: [String: TrafficBytes]
        if let h = selectedHour {
            procSource = record.hourlyProcesses[h] ?? [:]
            proxiedSource = record.hourlyProxiedClients[h] ?? [:]
        } else {
            procSource = record.processes
            proxiedSource = record.proxiedClients
        }

        // 归属已在写入账本时完成（客户端累加回填、代理行按窗口扣减），这里直接展示，避免按日累计相减导致行内数值倒退
        // 归一化进程名（历史上曾因前导空格产生「 curl」与「curl」两行，合并展示）
        var normalizedProcesses: [String: TrafficBytes] = [:]
        for (name, bytes) in procSource {
            let key = name.trimmingCharacters(in: .whitespaces)
            var current = normalizedProcesses[key] ?? TrafficBytes()
            current.add(bytes)
            normalizedProcesses[key] = current
        }
        var normalizedProxied: [String: TrafficBytes] = [:]
        for (name, bytes) in proxiedSource {
            let key = name.trimmingCharacters(in: .whitespaces)
            var current = normalizedProxied[key] ?? TrafficBytes()
            current.add(bytes)
            normalizedProxied[key] = current
        }

        for (name, bytes) in normalizedProcesses {
            let path = appPaths[name]
            let displayName: String

            if let p = path, let enclosing = Self.findEnclosingAppPath(path: p) {
                displayName = URL(fileURLWithPath: enclosing).deletingPathExtension().lastPathComponent
            } else {
                displayName = name
            }

            let pid = activePIDs[name] ?? 0
            let isRelay = Self.checkIsRelay(name: name, displayName: displayName)
            let proxied = normalizedProxied[name] ?? TrafficBytes()
            let effectiveBytes = bytes

            items.append(
                TrafficProcessItem(
                    name: name,
                    displayName: displayName,
                    pid: pid,
                    appBundlePath: path,
                    bytes: effectiveBytes,
                    isRelay: isRelay,
                    proxied: proxied
                )
            )
        }

        // Filter by search text
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter { item in
                item.displayName.lowercased().contains(query) ||
                item.name.lowercased().contains(query)
            }
        }

        // Sort items
        return items.sorted { a, b in
            switch sortField {
            case .total:
                return sortAscending ? a.bytes.total < b.bytes.total : a.bytes.total > b.bytes.total
            case .download:
                return sortAscending ? a.bytes.received < b.bytes.received : a.bytes.received > b.bytes.received
            case .upload:
                return sortAscending ? a.bytes.sent < b.bytes.sent : a.bytes.sent > b.bytes.sent
            case .name:
                let comp = a.displayName.localizedStandardCompare(b.displayName)
                return sortAscending ? comp == .orderedAscending : comp == .orderedDescending
            }
        }
    }

    // MARK: - Trend Series Data Sources

    public struct TrafficDaySummary: Identifiable, Sendable {
        public var id: String { dateString }
        public var dateString: String
        public var label: String
        public var shortDateLabel: String
        public var received: UInt64
        public var sent: UInt64
        public var total: UInt64

        public init(dateString: String, label: String, shortDateLabel: String, received: UInt64, sent: UInt64, total: UInt64) {
            self.dateString = dateString
            self.label = label
            self.shortDateLabel = shortDateLabel
            self.received = received
            self.sent = sent
            self.total = total
        }
    }

    /// Returns daily traffic records for historical trend charts (e.g. past 7 or 30 days)
    public func historySeries(days count: Int = 7) -> [TrafficDaySummary] {
        let calendar = Calendar.current
        let today = Date()
        var results: [TrafficDaySummary] = []

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "M/d"

        for offset in (0..<count).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayKey = TrafficDateKeys.day(date, calendar: calendar)
            let shortDate = dayFormatter.string(from: date)
            let label = offset == 0 ? "今天" : (offset == 1 ? "昨天" : shortDate)
            let dayRecord = ledger.days[dayKey] ?? TrafficDayRecord()
            results.append(TrafficDaySummary(
                dateString: dayKey,
                label: label,
                shortDateLabel: shortDate,
                received: dayRecord.physical.received,
                sent: dayRecord.physical.sent,
                total: dayRecord.physical.total
            ))
        }

        return results
    }

    /// Returns 24-hour hourly traffic for today (0..23)
    public func todayHourlyTrendData() -> [(hour: Int, received: UInt64, sent: UInt64, total: UInt64)] {
        let todayKey = TrafficDateKeys.day(Date())
        let record = ledger.days[todayKey] ?? TrafficDayRecord()
        var results: [(hour: Int, received: UInt64, sent: UInt64, total: UInt64)] = []

        for h in 0..<24 {
            let bytes = record.hourly[h] ?? TrafficBytes()
            results.append((hour: h, received: bytes.received, sent: bytes.sent, total: bytes.total))
        }

        return results
    }

    // MARK: - Monitoring Lifecycle

    public var isMonitoring: Bool {
        timer != nil
    }

    public func startMonitoring() {
        guard timer == nil else { return }
        sample()
        // 3 s 整机速率（sysctl 零子进程）；进程排行在 sample() 内按 15 s 降频采样。
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
    }

    /// Single source of truth for "throw away the diff baseline".
    ///
    /// Every path that stops, pauses or clears monitoring must reset **all four**
    /// baselines (`oldTime`, `oldProcesses`, `oldLoopback`, `oldInterfaces`).
    /// A partial reset re-diffs the next window against stale counters, which
    /// shows up as a phantom spike containing everything that flowed while the
    /// panel was closed (e.g. across a lid-close sleep).
    private func resetBaselines() {
        oldTime = nil
        oldProcesses.removeAll()
        oldLoopback.removeAll()
        oldInterfaces.removeAll()
        lastProcessSampleTime = nil
        lastPSRefreshTime = .distantPast
        clearPendingSampleWindow()
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        resetBaselines()
        currentDownloadRate = 0
        currentUploadRate = 0
        save()
    }

    public func togglePause() {
        isPaused.toggle()
        resetBaselines()
        currentDownloadRate = 0
        currentUploadRate = 0
        statusMessage = isPaused ? "已暂停统计" : "采集中"
        if !isPaused {
            sample()
        }
    }

    public func clearTodayData() {
        let todayKey = TrafficDateKeys.day(Date())
        ledger.clear(day: todayKey)
        resetBaselines()
        save()
    }

    public func clearAllData() {
        ledger.clearAll()
        resetBaselines()
        save()
    }

    public func refresh() async {
        guard !inFlight else { return }
        isLoading = true
        sample(forceProcessSample: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        isLoading = false
    }

    // MARK: - Sampling Pipeline

    /// - Parameter forceProcessSample: bypasses the 15 s process-ranking cadence.
    ///   Used when a panel opens or the user hits refresh, so the ranking is not
    ///   stale on first paint.
    public func sample(forceProcessSample: Bool = false) {
        // Watchdog: a wedged `nettop` / `ps` child, or a lost main-queue hop,
        // would otherwise leave `inFlight` true forever — sampling would stop
        // silently while the panel still claims "采集中". 20 s is well past the
        // 8 s + 2 s child timeout, so a legitimately slow sample never trips it.
        if inFlight, let since = inFlightSince, Date().timeIntervalSince(since) > 20 {
            let stalled = Date().timeIntervalSince(since)
            inFlight = false
            inFlightSince = nil
            statusMessage = "采样超时，已自动恢复"
            AppLog.traffic.warning("sampling watchdog tripped after \(stalled, privacy: .public)s — child process or main-queue hop never returned")
        }
        guard !inFlight, !isPaused else { return }
        inFlight = true
        inFlightSince = Date()

        let now = Date()
        let netContext: TrafficNetworkContext
        if forceProcessSample {
            netContext = detectCurrentNetwork()
            cachedNetworkContextValue = netContext
            cachedNetworkContextAt = now
        } else {
            netContext = cachedNetworkContext(now: now)
        }
        self.currentNetwork = netContext
        if selectedNetwork != "__all__" && !availableNetworkNames.contains(selectedNetwork) {
            selectedNetwork = "__all__"
        }

        let samplingNetwork = netContext
        // `oldTime == nil` means first tick after launch/wake: always re-baseline
        // the process counters so the next diff starts from a clean snapshot.
        let shouldSampleProcesses = forceProcessSample
            || oldTime == nil
            || lastProcessSampleTime.map { now.timeIntervalSince($0) >= processSampleInterval } ?? true
        let shouldRefreshPS = forceProcessSample || now.timeIntervalSince(lastPSRefreshTime) >= psRefreshInterval
        if shouldSampleProcesses { lastProcessSampleTime = now }
        if shouldRefreshPS { lastPSRefreshTime = now }

        sampleQueue.async { [weak self] in
            autoreleasepool {
                let proxyPorts = shouldSampleProcesses ? Self.detectLocalProxyPorts() : []
                // -t external: 严格排除 loopback 回环 (127.0.0.1/lo0)，只统计实际外部物理网卡流量 (Wi-Fi / Ethernet)
                let procResult = shouldSampleProcesses
                    ? Self.runCommand("/usr/bin/nettop", ["-t", "external", "-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out"])
                    : (text: "", success: false)
                // -t loopback: 仅在检测到本机代理时采样。逐条 flow 可判定「该 socket 的对端是否为代理端口」，用于把经代理转发的流量回填到真实客户端应用名下
                let loopResult = (shouldSampleProcesses && !proxyPorts.isEmpty)
                    ? Self.runCommand("/usr/bin/nettop", ["-x", "-t", "loopback", "-l", "1"])
                    : (text: "", success: false)
                // 整机计数器直接读内核 64 位接口统计，零子进程、无 4 GB 回绕。
                let interfaces = Self.readInterfaceCounters()
                let psResult = shouldRefreshPS
                    ? Self.runCommand("/bin/ps", ["-axo", "pid=,comm="])
                    : (text: "", success: false)

                DispatchQueue.main.async {
                    self?.applySampleResults(
                        proc: procResult,
                        loop: loopResult,
                        interfaces: interfaces,
                        psOutput: psResult.text,
                        psRefreshed: shouldRefreshPS,
                        processSampled: shouldSampleProcesses,
                        now: Date(),
                        network: samplingNetwork,
                        proxyPorts: proxyPorts
                    )
                }
            }
        }
    }

    private func cachedNetworkContext(now: Date) -> TrafficNetworkContext {
        if let cached = cachedNetworkContextValue,
           now.timeIntervalSince(cachedNetworkContextAt) < networkContextTTL {
            return cached
        }
        let context = detectCurrentNetwork()
        cachedNetworkContextValue = context
        cachedNetworkContextAt = now
        return context
    }

    private func wifiInterfaceNames() -> Set<String> {
        let now = Date()
        if now.timeIntervalSince(cachedWiFiInterfaceNamesAt) < wifiInterfaceTTL {
            return cachedWiFiInterfaceNames
        }
        let names = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        cachedWiFiInterfaceNames = names
        cachedWiFiInterfaceNamesAt = now
        return names
    }

    /// Drops a partially accumulated ledger window. Called whenever the clock
    /// baseline is reset (launch, wake, pause) so sleep/pause bytes never land
    /// in a later window.
    private func clearPendingSampleWindow() {
        pendingPhysical = TrafficBytes()
        pendingWiFi = TrafficBytes()
        pendingEthernet = TrafficBytes()
        pendingInterval = 0
    }

    /// 读取系统代理配置，仅当代理指向本机回环地址时返回端口集合。
    nonisolated private static func detectLocalProxyPorts() -> [Int] {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return [] }

        var ports: [Int] = []
        func collect(_ enableKey: String, _ hostKey: String, _ portKey: String) {
            guard let enabled = proxies[enableKey] as? Bool, enabled,
                  let host = proxies[hostKey] as? String,
                  let port = proxies[portKey] as? Int, port > 0 else { return }
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost" else { return }
            if !ports.contains(port) { ports.append(port) }
        }

        collect(kSCPropNetProxiesHTTPEnable as String, kSCPropNetProxiesHTTPProxy as String, kSCPropNetProxiesHTTPPort as String)
        collect(kSCPropNetProxiesHTTPSEnable as String, kSCPropNetProxiesHTTPSProxy as String, kSCPropNetProxiesHTTPSPort as String)
        collect(kSCPropNetProxiesSOCKSEnable as String, kSCPropNetProxiesSOCKSProxy as String, kSCPropNetProxiesSOCKSPort as String)
        return ports
    }

    /// 单进程在回环接口上的快照：累计字节 + 全部 flow 字节量 + 其中对端为代理端口的 flow 字节量
    private struct LoopbackSnapshot {
        var name: String
        var total: TrafficBytes
        var flowTotal: UInt64 = 0
        var flowProxied: UInt64 = 0
    }

    nonisolated private static func parseLoopbackSnapshot(_ text: String, proxyPorts: Set<Int>) -> [String: LoopbackSnapshot] {
        var result: [String: LoopbackSnapshot] = [:]
        var currentPID: String?

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard line != "" else { continue }
            guard let body = bodyAfterTimestamp(line) else { continue }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // flow 行：tcp4 <local><-><remote>  <if>  <state>  <bytes_in>  <bytes_out>
            if trimmed.hasPrefix("tcp4 ") || trimmed.hasPrefix("tcp6 ")
                || trimmed.hasPrefix("udp4 ") || trimmed.hasPrefix("udp6 ") {
                guard let pid = currentPID, var entry = result[pid] else { continue }
                let fields = trimmed.split(whereSeparator: { $0 == " " }).map(String.init)
                guard fields.count >= 6,
                      let bytesIn = UInt64(fields[4]),
                      let bytesOut = UInt64(fields[5]) else { continue }
                let endpoints = fields[1].components(separatedBy: "<->")
                guard endpoints.count == 2 else { continue }

                // flow 级计数只用于「判定这条 socket 的对端是不是代理端口」并据此估算占比；
                // 其数值不能当流量总量做差分（实测严重偏低/滞后），体量一律以进程累计计数为准。
                let flowBytes = bytesIn + bytesOut
                entry.flowTotal += flowBytes
                if let remotePort = endpointPort(endpoints[1]), proxyPorts.contains(remotePort) {
                    entry.flowProxied += flowBytes
                }
                result[pid] = entry
                continue
            }

            // 进程汇总行：<name>.<pid>  <bytes_in>  <bytes_out> ...
            guard let separator = body.range(of: "  ") else { continue }
            let label = String(body[..<separator.lowerBound])
            let tail = String(body[separator.lowerBound...])
            guard let dot = label.lastIndex(of: "."), dot < label.endIndex,
                  let pid = Int(label[label.index(after: dot)...]) else { continue }
            let name = String(label[..<dot]).trimmingCharacters(in: .whitespaces)
            let numbers = tail.split(whereSeparator: { $0 == " " }).compactMap { UInt64($0) }
            let received = numbers.first ?? 0
            let sent = numbers.count > 1 ? numbers[1] : 0

            result[String(pid)] = LoopbackSnapshot(
                name: name,
                total: TrafficBytes(received: received, sent: sent)
            )
            currentPID = String(pid)
        }
        return result
    }

    /// 去掉行首时间戳列（`13:03:27.242309`），返回其后的内容；表头行返回 nil。
    nonisolated private static func bodyAfterTimestamp(_ line: String) -> String? {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let head = line[line.startIndex..<sep]
        guard head.contains(":"), head.contains(".") else { return nil }
        return String(line[sep...])
    }

    /// 从 `127.0.0.1:7890` / `localhost:7890` / `::1.7890` 这类端点串里取出端口。
    nonisolated private static func endpointPort(_ endpoint: String) -> Int? {
        guard let last = endpoint.lastIndex(where: { $0 == ":" || $0 == "." }) else { return nil }
        return Int(endpoint[endpoint.index(after: last)...])
    }

    private func applySampleResults(
        proc: (text: String, success: Bool),
        loop: (text: String, success: Bool),
        interfaces: [String: TrafficBytes],
        psOutput: String,
        psRefreshed: Bool,
        processSampled: Bool,
        now: Date,
        network: TrafficNetworkContext,
        proxyPorts: [Int] = []
    ) {
        inFlight = false
        inFlightSince = nil
        guard !isPaused else {
            oldTime = nil
            return
        }

        if processSampled {
            localProxyPorts = proxyPorts
        }
        let parsedProcesses = (processSampled && proc.success) ? Self.parseProcesses(proc.text) : [:]
        let parsedInterfaces = interfaces
        let proxyPortSet = Set(localProxyPorts)
        let parsedLoopback = (processSampled && loop.success)
            ? Self.parseLoopbackSnapshot(loop.text, proxyPorts: proxyPortSet)
            : [:]

        // Whole-machine counters come from the kernel and are always available;
        // a failed/throttled process sample must not blank the live rates.
        guard !parsedInterfaces.isEmpty else {
            statusMessage = "采集异常：无法读取网络接口计数器"
            currentDownloadRate = 0
            currentUploadRate = 0
            oldTime = nil
            return
        }

        if psRefreshed {
            let mapping = Self.parseProcessPaths(psOutput)
            if !mapping.isEmpty {
                pidMapping = mapping
                var currentActivePIDs: [String: pid_t] = [:]
                currentActivePIDs.reserveCapacity(mapping.count)
                for (pidStr, item) in mapping {
                    if let pidNum = pid_t(pidStr) {
                        currentActivePIDs[item.name] = pidNum
                    }
                    if item.path.contains(".app") {
                        appPaths[item.name] = item.path
                    }
                }
                activePIDs = currentActivePIDs
            }
        }

        if let previous = oldTime {
            let interval = now.timeIntervalSince(previous)
            if interval > 0 && interval < 45 {
                var physical = TrafficBytes()
                var wifiBytes = TrafficBytes()
                var ethernetBytes = TrafficBytes()

                let wifiInterfaces = wifiInterfaceNames()

                for (name, val) in parsedInterfaces {
                    if let oldVal = oldInterfaces[name] {
                        let diff = val.difference(from: oldVal)
                        physical.add(diff)
                        if wifiInterfaces.contains(name) {
                            wifiBytes.add(diff)
                        } else {
                            ethernetBytes.add(diff)
                        }
                    }
                }

                // Live rates always use the 3 s interface diff; the ledger is
                // written on the slower process cadence so physical and process
                // bytes always cover the same window.
                currentDownloadRate = Double(physical.received) / interval
                currentUploadRate = Double(physical.sent) / interval

                pendingPhysical.add(physical)
                pendingWiFi.add(wifiBytes)
                pendingEthernet.add(ethernetBytes)
                pendingInterval += interval

                if processSampled {
                    var processDeltas: [String: TrafficBytes] = [:]
                    for (key, val) in parsedProcesses {
                        guard let oldVal = oldProcesses[key], oldVal.name == val.name else { continue }
                        let delta = val.bytes.difference(from: oldVal.bytes)
                        guard delta.total > 0 else { continue }

                        let pidString = key.split(separator: ".").last.map(String.init) ?? ""
                        let mappedName = pidMapping[pidString]?.name ?? val.name
                        if let pidNum = pid_t(pidString) {
                            activePIDs[mappedName] = pidNum
                        }
                        var existing = processDeltas[mappedName] ?? TrafficBytes()
                        existing.add(delta)
                        processDeltas[mappedName] = existing
                    }

                    // 经本机代理转发、按回环归属回填到真实客户端应用名下的字节。
                    // 体量取「进程回环累计差分」（单调、可信），再乘以「对端为代理端口的 flow 占比」剥离本地 RPC。
                    var proxiedDeltas: [String: TrafficBytes] = [:]
                    let relayPresent = processDeltas.keys.contains { Self.checkIsRelay(name: $0, displayName: $0) }
                    if !proxyPortSet.isEmpty, relayPresent, !parsedLoopback.isEmpty {
                        for (pid, snapshot) in parsedLoopback {
                            guard snapshot.flowProxied > 0, snapshot.flowTotal > 0 else { continue }

                            // 新出现的进程（或 PID 被复用）：其生命周期计数即为本窗口增量；老进程走差分
                            let delta: TrafficBytes
                            if let previous = oldLoopback[pid], previous.name == snapshot.name {
                                delta = snapshot.total.difference(from: previous.total)
                            } else {
                                delta = snapshot.total
                            }
                            guard delta.total > 0 else { continue }

                            let share = Double(snapshot.flowProxied) / Double(snapshot.flowTotal)
                            let received = UInt64(Double(delta.received) * share)
                            let sent = UInt64(Double(delta.sent) * share)
                            guard received + sent > 0 else { continue }

                            let mappedName = pidMapping[pid]?.name ?? snapshot.name
                            // 代理进程自身不回填，避免自计数
                            if Self.checkIsRelay(name: mappedName, displayName: mappedName) { continue }

                            var existing = proxiedDeltas[mappedName] ?? TrafficBytes()
                            existing.add(TrafficBytes(received: received, sent: sent))
                            proxiedDeltas[mappedName] = existing
                        }

                        // 硬约束：回填总量不得超过代理进程本窗口的物理转发量（下载/上传分别裁剪），
                        // 保证「进程排行上传/下载合计」永不大于整机口径
                        var relayReceived: UInt64 = 0
                        var relaySent: UInt64 = 0
                        for (name, delta) in processDeltas where Self.checkIsRelay(name: name, displayName: name) {
                            relayReceived += delta.received
                            relaySent += delta.sent
                        }
                        let attributedReceived = proxiedDeltas.values.reduce(0) { $0 + $1.received }
                        let attributedSent = proxiedDeltas.values.reduce(0) { $0 + $1.sent }
                        let scaleReceived = attributedReceived > relayReceived
                            ? Double(relayReceived) / Double(attributedReceived) : 1
                        let scaleSent = attributedSent > relaySent
                            ? Double(relaySent) / Double(attributedSent) : 1

                        if scaleReceived < 1 || scaleSent < 1 {
                            for (name, value) in proxiedDeltas {
                                proxiedDeltas[name] = TrafficBytes(
                                    received: UInt64(Double(value.received) * scaleReceived),
                                    sent: UInt64(Double(value.sent) * scaleSent)
                                )
                            }
                        }
                    }

                    // 归属就地写入进程增量：客户端行加上回填量，代理行扣掉已归属量（逐窗口扣减，保证累计单调不倒挂）
                    if !proxiedDeltas.isEmpty {
                        let attributedReceived = proxiedDeltas.values.reduce(0) { $0 + $1.received }
                        let attributedSent = proxiedDeltas.values.reduce(0) { $0 + $1.sent }
                        var relayTotalReceived: UInt64 = 0
                        var relayTotalSent: UInt64 = 0
                        for (name, delta) in processDeltas where Self.checkIsRelay(name: name, displayName: name) {
                            relayTotalReceived += delta.received
                            relayTotalSent += delta.sent
                        }

                        for (name, delta) in processDeltas where Self.checkIsRelay(name: name, displayName: name) {
                            let shareReceived = relayTotalReceived > 0 ? Double(delta.received) / Double(relayTotalReceived) : 0
                            let shareSent = relayTotalSent > 0 ? Double(delta.sent) / Double(relayTotalSent) : 0
                            let cutReceived = UInt64(Double(attributedReceived) * shareReceived)
                            let cutSent = UInt64(Double(attributedSent) * shareSent)
                            processDeltas[name] = TrafficBytes(
                                received: delta.received > cutReceived ? delta.received - cutReceived : 0,
                                sent: delta.sent > cutSent ? delta.sent - cutSent : 0
                            )
                        }

                        for (name, value) in proxiedDeltas {
                            var current = processDeltas[name] ?? TrafficBytes()
                            current.add(value)
                            processDeltas[name] = current
                        }
                    }

                    // A failed nettop run keeps the window open so the next
                    // successful sample still matches physical bytes. After a
                    // minute, write physical-only and reset the process baseline.
                    let canWriteLedger = proc.success || pendingInterval >= 60
                    if canWriteLedger {
                        let dayKey = TrafficDateKeys.day(now)
                        let currentHour = Calendar.current.component(.hour, from: now)
                        let ledgerProcesses = proc.success ? processDeltas : [:]
                        let ledgerProxied = proc.success ? proxiedDeltas : [:]
                        let wifiDominant = pendingWiFi.total >= pendingEthernet.total

                        // 1. All networks aggregate
                        ledger.add(
                            day: dayKey,
                            hour: currentHour,
                            physical: pendingPhysical,
                            processes: ledgerProcesses,
                            seconds: pendingInterval,
                            network: .all,
                            proxiedClients: ledgerProxied
                        )

                        // 2. Wi-Fi network stream
                        if pendingWiFi.total > 0 {
                            let wifiCtx = TrafficNetworkContext(
                                key: network.key.hasPrefix("wifi:") ? network.key : "wifi:Wi-Fi",
                                name: network.key.hasPrefix("wifi:") ? network.name : "Wi-Fi (无线网络)",
                                type: .wifi,
                                identified: true
                            )
                            ledger.add(
                                day: dayKey,
                                hour: currentHour,
                                physical: pendingWiFi,
                                processes: wifiDominant ? ledgerProcesses : [:],
                                seconds: pendingInterval,
                                network: wifiCtx,
                                proxiedClients: wifiDominant ? ledgerProxied : [:]
                            )
                        }

                        // 3. Wired Ethernet stream
                        if pendingEthernet.total > 0 {
                            let ethCtx = TrafficNetworkContext(
                                key: "ethernet:wired",
                                name: "有线网卡 (以太网)",
                                type: .ethernet,
                                identified: true
                            )
                            ledger.add(
                                day: dayKey,
                                hour: currentHour,
                                physical: pendingEthernet,
                                processes: wifiDominant ? [:] : ledgerProcesses,
                                seconds: pendingInterval,
                                network: ethCtx,
                                proxiedClients: wifiDominant ? [:] : ledgerProxied
                            )
                        }

                        clearPendingSampleWindow()
                        if !proc.success {
                            // Physical was written without a process counterpart;
                            // start the next process diff from a clean baseline.
                            oldProcesses.removeAll()
                            oldLoopback.removeAll()
                        }
                    }
                }

                if now.timeIntervalSince(lastSaved) >= 60 {
                    save()
                    lastSaved = now
                }
            } else {
                currentDownloadRate = 0
                currentUploadRate = 0
                // The gap is too large to trust; drop the partial window and
                // re-baseline process counters on the next successful sample.
                clearPendingSampleWindow()
                oldProcesses.removeAll()
                oldLoopback.removeAll()
            }
        }

        // Process counters are only re-baselined on a successful sample; a failed
        // nettop run must keep the old baseline so the next diff stays exact.
        if processSampled && proc.success {
            oldProcesses = parsedProcesses
            oldLoopback = parsedLoopback
        }
        oldInterfaces = parsedInterfaces
        oldTime = now
        lastSampleTime = now
        statusMessage = "采集中"
    }

    // MARK: - Icon Loading & Resolution (Aligned with ProcessManager)

    public func resolveIcon(for item: TrafficProcessItem) -> NSImage? {
        if let icon = processIcons[item.displayName] {
            return icon
        }

        // 1. Try NSRunningApplication by active PID
        if item.pid > 0, let runningIcon = NSRunningApplication(processIdentifier: item.pid)?.icon {
            processIcons[item.displayName] = runningIcon
            return runningIcon
        }

        // 2. Try enclosing .app bundle path
        if let path = item.appBundlePath ?? appPaths[item.name],
           let enclosing = Self.findEnclosingAppPath(path: path) {
            let icon = NSWorkspace.shared.icon(forFile: enclosing)
            if icon.isValid {
                processIcons[item.displayName] = icon
                return icon
            }
        }

        // 3. Try standard application search by displayName
        let appName = item.displayName.hasSuffix(".app") ? item.displayName : "\(item.displayName).app"
        let systemAppPaths = [
            "/Applications/\(appName)",
            "/System/Applications/\(appName)",
            "/System/Applications/Utilities/\(appName)",
            "\(NSHomeDirectory())/Applications/\(appName)"
        ]
        for p in systemAppPaths where FileManager.default.fileExists(atPath: p) {
            let icon = NSWorkspace.shared.icon(forFile: p)
            if icon.isValid {
                processIcons[item.displayName] = icon
                return icon
            }
        }

        return nil
    }

    public static func findEnclosingAppPath(path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        var topAppURL: URL? = nil
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" {
                topAppURL = url
            }
            url = url.deletingLastPathComponent()
        }
        return topAppURL?.path
    }

    // MARK: - Persistence

    public func save() {
        let today = TrafficDateKeys.day(Date())
        if lastPrunedDay != today {
            ledger.pruneOldDays(keepingDays: 90)
            lastPrunedDay = today
        }
        let snapshot = ledger
        let fileURL = ledgerFileURL
        saveQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                let message = "历史数据写入异常: \(error.localizedDescription)"
                AppLog.traffic.error("ledger save failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in
                    self?.statusMessage = message
                }
            }
        }
    }

    // MARK: - CSV Export

    public func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pinner-流量账本-\(TrafficDateKeys.day(Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var csv = "日期,网络类型,网络名称,下载字节,上传字节,总字节,监控时长(秒)\n"

        for key in ledger.days.keys.sorted() {
            guard let d = ledger.days[key] else { continue }
            csv += CSVField.row([key, "全部网络", "整机汇总", "\(d.physical.received)", "\(d.physical.sent)", "\(d.physical.total)", "\(Int(d.monitoredSeconds))"]) + "\n"
            for (name, b) in d.processes.sorted(by: { $0.value.total > $1.value.total }) {
                csv += CSVField.row([key, "全部网络", name, "\(b.received)", "\(b.sent)", "\(b.total)", ""]) + "\n"
            }
        }

        for history in ledger.networks.values.sorted(by: { $0.name < $1.name }) {
            let netType = history.type ?? "自定义网络"
            for key in history.days.keys.sorted() {
                guard let d = history.days[key] else { continue }
                csv += CSVField.row([key, netType, history.name, "\(d.physical.received)", "\(d.physical.sent)", "\(d.physical.total)", "\(Int(d.monitoredSeconds))"]) + "\n"
                for (name, b) in d.processes.sorted(by: { $0.value.total > $1.value.total }) {
                    csv += CSVField.row([key, history.name, name, "\(b.received)", "\(b.sent)", "\(b.total)", ""]) + "\n"
                }
            }
        }

        do {
            try ("\u{FEFF}" + csv).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Network & Hotspot Detection

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let expensive = path.isExpensive
        let constrained = path.isConstrained
        self.isExpensiveNetwork = expensive
        self.isConstrainedNetwork = constrained

        let netContext = detectCurrentNetwork()
        self.currentNetwork = netContext
        self.cachedNetworkContextValue = netContext
        self.cachedNetworkContextAt = Date()
        self.isHotspotActive = netContext.isHotspot || expensive
        self.hotspotName = self.isHotspotActive ? netContext.name : nil
    }

    private func detectCurrentNetwork() -> TrafficNetworkContext {
        let client = CWWiFiClient.shared()
        for name in client.interfaceNames() ?? [] {
            if let ssid = client.interface(withName: name)?.ssid(), !ssid.isEmpty {
                let isHotspot = isHotspotSSID(ssid) || isExpensiveNetwork
                return TrafficNetworkContext(
                    key: "wifi:\(ssid)",
                    name: isHotspot ? "移动热点 (\(ssid))" : "Wi-Fi: \(ssid)",
                    type: .wifi,
                    identified: true,
                    isHotspot: isHotspot
                )
            }
        }
        if isExpensiveNetwork {
            return TrafficNetworkContext(
                key: "hotspot:cellular",
                name: "移动热点 (计费网络)",
                type: .all,
                identified: true,
                isHotspot: true
            )
        }
        return .all
    }

    private func isHotspotSSID(_ ssid: String) -> Bool {
        let s = ssid.lowercased()
        let keywords = ["iphone", "ipad", "hotspot", "热点", "mobile", "mifi", "huawei", "4g", "5g", "pixel", "galaxy", "cellular"]
        return keywords.contains(where: { s.contains($0) })
    }

    // MARK: - Relay / Proxy Detection

    nonisolated private static func checkIsRelay(name: String, displayName: String) -> Bool {
        let relays = [
            "clash", "surge", "sing-box", "mihomo", "shadowrocket", "v2ray",
            "xray", "trojan", "quantumult", "tailscale", "wireguard", "openvpn",
            "qv2ray", "nekoray", "dae", "snell", "kumiryo"
        ]
        let lowerName = name.lowercased()
        let lowerDisplay = displayName.lowercased()
        return relays.contains(where: { lowerName.contains($0) || lowerDisplay.contains($0) })
    }

    // MARK: - Shell Command Execution

    nonisolated private static func runCommand(_ path: String, _ arguments: [String]) -> (text: String, success: Bool) {
        let result = SubprocessRunner.run(path, arguments, timeout: 8.0, forceCLocale: true)
        return (result.output, result.succeeded)
    }

    // MARK: - Parsers

    nonisolated private static func parseProcesses(_ text: String) -> [String: TrafficProcessCounter] {
        var result: [String: TrafficProcessCounter] = [:]
        for line in text.split(separator: "\n") {
            let values = line.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count >= 3,
                  let separator = values[0].lastIndex(of: "."),
                  Int(values[0][values[0].index(after: separator)...]) != nil,
                  let received = UInt64(values[1]),
                  let sent = UInt64(values[2]) else { continue }
            let name = String(values[0])
            let baseName = String(values[0][..<separator])
            result[name] = TrafficProcessCounter(
                name: baseName,
                bytes: TrafficBytes(received: received, sent: sent)
            )
        }
        return result
    }

    /// Reads 64-bit per-interface counters straight from the kernel.
    ///
    /// `netstat -ibn` was a subprocess every 3 s. `getifaddrs` is cheaper but
    /// exposes 32-bit `if_data` counters that wrap at 4 GB, so use
    /// `NET_RT_IFLIST2`, which carries `if_data64`.
    nonisolated private static func readInterfaceCounters() -> [String: TrafficBytes] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var buffer = [UInt8]()
        var length: size_t = 0
        var readSucceeded = false

        // The interface list can grow between the sizing call and the read, so
        // retry a couple of times instead of silently dropping the sample.
        for _ in 0..<3 {
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
                return [:]
            }
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                readSucceeded = true
                break
            }
        }
        guard readSucceeded, length > 0, !buffer.isEmpty else { return [:] }

        var result: [String: TrafficBytes] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr2>.size <= Int(length) {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self)
                let messageLength = Int(header.pointee.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= Int(length) else { break }

                if Int32(header.pointee.ifm_type) == RTM_IFINFO2 {
                    // The interface name lives in the sockaddr_dl immediately
                    // after the fixed header; sdl_data starts at byte 8.
                    let nameOffset = offset + MemoryLayout<if_msghdr2>.size
                    if nameOffset + MemoryLayout<sockaddr_dl>.size <= offset + messageLength {
                        let link = base.advanced(by: nameOffset).assumingMemoryBound(to: sockaddr_dl.self)
                        let nameLength = Int(link.pointee.sdl_nlen)
                        if nameLength > 0, nameLength <= Int(link.pointee.sdl_len) - 8 {
                            let namePointer = UnsafeRawPointer(link)
                                .advanced(by: 8)
                                .assumingMemoryBound(to: UInt8.self)
                            let name = String(
                                bytes: UnsafeBufferPointer(start: namePointer, count: nameLength),
                                encoding: .utf8
                            ) ?? ""
                            if name.hasPrefix("en") {
                                let data = header.pointee.ifm_data
                                result[name] = TrafficBytes(
                                    received: data.ifi_ibytes,
                                    sent: data.ifi_obytes
                                )
                            }
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    nonisolated private static func parseProcessPaths(_ text: String) -> [String: (name: String, path: String)] {
        var result: [String: (name: String, path: String)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            let pid = String(parts[0])
            let path = String(parts[1])

            if let end = path.range(of: ".app/") {
                let app = String(path[..<end.lowerBound]) + ".app"
                let name = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
                result[pid] = (name, app)
            } else if path.contains("/claude/") || path.contains("/claude-code/") {
                result[pid] = ("Claude Code", path)
            } else {
                let name = URL(fileURLWithPath: path).lastPathComponent
                result[pid] = (name, path)
            }
        }
        return result
    }
}
