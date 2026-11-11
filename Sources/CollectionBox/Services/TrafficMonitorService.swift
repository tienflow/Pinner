import Foundation
import AppKit
import CoreWLAN
import Network
import SystemConfiguration

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
    private var oldProcesses: [String: TrafficProcessCounter] = [:]
    private var oldLoopback: [String: LoopbackSnapshot] = [:]
    private var oldInterfaces: [String: TrafficBytes] = [:]
    private var oldTime: Date?
    private var lastSaved: Date = .distantPast
    private var lastPrunedDay: String?
    private var appPaths: [String: String] = [:]
    private var pidMapping: [String: (name: String, path: String)] = [:]
    private var activePIDs: [String: pid_t] = [:]

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
            guard let self else { return }
            self.oldTime = nil
            if self.timer != nil {
                self.sample()
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
        // 3s 采样：nettop 单次仅 0.01–0.16s，缩短窗口可显著减少「连接在两次采样之间关闭」导致的漏计
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        oldTime = nil
        oldLoopback.removeAll()
        currentDownloadRate = 0
        currentUploadRate = 0
        save()
    }

    public func togglePause() {
        isPaused.toggle()
        oldTime = nil
        oldLoopback.removeAll()
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
        oldProcesses.removeAll()
        oldLoopback.removeAll()
        oldInterfaces.removeAll()
        oldTime = nil
        save()
    }

    public func clearAllData() {
        ledger.clearAll()
        oldProcesses.removeAll()
        oldLoopback.removeAll()
        oldInterfaces.removeAll()
        oldTime = nil
        save()
    }

    public func refresh() async {
        guard !inFlight else { return }
        isLoading = true
        sample()
        try? await Task.sleep(nanoseconds: 600_000_000)
        isLoading = false
    }

    // MARK: - Sampling Pipeline

    public func sample() {
        guard !inFlight, !isPaused else { return }
        inFlight = true

        let netContext = detectCurrentNetwork()
        self.currentNetwork = netContext
        if selectedNetwork != "__all__" && !availableNetworkNames.contains(selectedNetwork) {
            selectedNetwork = "__all__"
        }

        let samplingNetwork = netContext

        sampleQueue.async { [weak self] in
            autoreleasepool {
                let proxyPorts = Self.detectLocalProxyPorts()
                // -t external: 严格排除 loopback 回环 (127.0.0.1/lo0)，只统计实际外部物理网卡流量 (Wi-Fi / Ethernet)
                let procResult = Self.runCommand("/usr/bin/nettop", ["-t", "external", "-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out"])
                // -t loopback: 仅在检测到本机代理时采样。逐条 flow 可判定「该 socket 的对端是否为代理端口」，用于把经代理转发的流量回填到真实客户端应用名下
                let loopResult = proxyPorts.isEmpty
                    ? (text: "", success: false)
                    : Self.runCommand("/usr/bin/nettop", ["-x", "-t", "loopback", "-l", "1"])
                let netResult = Self.runCommand("/usr/sbin/netstat", ["-ibn"])
                let psResult = Self.runCommand("/bin/ps", ["-axo", "pid=,comm="])
                let now = Date()

                DispatchQueue.main.async {
                    self?.applySampleResults(
                        proc: procResult,
                        loop: loopResult,
                        net: netResult,
                        psOutput: psResult.text,
                        now: now,
                        network: samplingNetwork,
                        proxyPorts: proxyPorts
                    )
                }
            }
        }
    }

    /// 读取系统代理配置，仅当代理指向本机回环地址时返回端口集合。
    private static func detectLocalProxyPorts() -> [Int] {
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

    private static func parseLoopbackSnapshot(_ text: String, proxyPorts: Set<Int>) -> [String: LoopbackSnapshot] {
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
    private static func bodyAfterTimestamp(_ line: String) -> String? {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let head = line[line.startIndex..<sep]
        guard head.contains(":"), head.contains(".") else { return nil }
        return String(line[sep...])
    }

    /// 从 `127.0.0.1:7890` / `localhost:7890` / `::1.7890` 这类端点串里取出端口。
    private static func endpointPort(_ endpoint: String) -> Int? {
        guard let last = endpoint.lastIndex(where: { $0 == ":" || $0 == "." }) else { return nil }
        return Int(endpoint[endpoint.index(after: last)...])
    }

    private func applySampleResults(
        proc: (text: String, success: Bool),
        loop: (text: String, success: Bool),
        net: (text: String, success: Bool),
        psOutput: String,
        now: Date,
        network: TrafficNetworkContext,
        proxyPorts: [Int] = []
    ) {
        inFlight = false
        guard !isPaused else {
            oldTime = nil
            return
        }

        localProxyPorts = proxyPorts
        let parsedProcesses = Self.parseProcesses(proc.text)
        let parsedInterfaces = Self.parseInterfaces(net.text)
        let proxyPortSet = Set(proxyPorts)
        let parsedLoopback = loop.success
            ? Self.parseLoopbackSnapshot(loop.text, proxyPorts: proxyPortSet)
            : [:]

        guard proc.success, !parsedProcesses.isEmpty, net.success, !parsedInterfaces.isEmpty else {
            statusMessage = "采集异常：无法获取网络计数器"
            currentDownloadRate = 0
            currentUploadRate = 0
            oldTime = nil
            return
        }

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

        if let previous = oldTime {
            let interval = now.timeIntervalSince(previous)
            if interval > 0 && interval < 45 {
                var physical = TrafficBytes()
                var wifiBytes = TrafficBytes()
                var ethernetBytes = TrafficBytes()

                let wifiInterfaces = Set(CWWiFiClient.shared().interfaceNames() ?? [])

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

                let dayKey = TrafficDateKeys.day(now)
                let currentHour = Calendar.current.component(.hour, from: now)

                // 1. All networks aggregate
                ledger.add(
                    day: dayKey,
                    hour: currentHour,
                    physical: physical,
                    processes: processDeltas,
                    seconds: interval,
                    network: .all,
                    proxiedClients: proxiedDeltas
                )

                // 2. Wi-Fi network stream
                let wifiDominant = wifiBytes.total >= ethernetBytes.total
                if wifiBytes.total > 0 {
                    let wifiCtx = TrafficNetworkContext(
                        key: network.key.hasPrefix("wifi:") ? network.key : "wifi:Wi-Fi",
                        name: network.key.hasPrefix("wifi:") ? network.name : "Wi-Fi (无线网络)",
                        type: .wifi,
                        identified: true
                    )
                    ledger.add(
                        day: dayKey,
                        hour: currentHour,
                        physical: wifiBytes,
                        processes: wifiDominant ? processDeltas : [:],
                        seconds: interval,
                        network: wifiCtx,
                        proxiedClients: wifiDominant ? proxiedDeltas : [:]
                    )
                }

                // 3. Wired Ethernet stream
                if ethernetBytes.total > 0 {
                    let ethCtx = TrafficNetworkContext(
                        key: "ethernet:wired",
                        name: "有线网卡 (以太网)",
                        type: .ethernet,
                        identified: true
                    )
                    ledger.add(
                        day: dayKey,
                        hour: currentHour,
                        physical: ethernetBytes,
                        processes: wifiDominant ? [:] : processDeltas,
                        seconds: interval,
                        network: ethCtx,
                        proxiedClients: wifiDominant ? [:] : proxiedDeltas
                    )
                }

                currentDownloadRate = Double(physical.received) / interval
                currentUploadRate = Double(physical.sent) / interval

                if now.timeIntervalSince(lastSaved) >= 60 {
                    save()
                    lastSaved = now
                }
            } else {
                currentDownloadRate = 0
                currentUploadRate = 0
            }
        }

        oldProcesses = parsedProcesses
        oldLoopback = parsedLoopback
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
            csv += "\(key),全部网络,整机汇总,\(d.physical.received),\(d.physical.sent),\(d.physical.total),\(Int(d.monitoredSeconds))\n"
            for (name, b) in d.processes.sorted(by: { $0.value.total > $1.value.total }) {
                let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\(key),全部网络,\"\(escaped)\",\(b.received),\(b.sent),\(b.total),\n"
            }
        }

        for history in ledger.networks.values.sorted(by: { $0.name < $1.name }) {
            let netType = history.type ?? "自定义网络"
            for key in history.days.keys.sorted() {
                guard let d = history.days[key] else { continue }
                let netEscaped = history.name.replacingOccurrences(of: "\"", with: "\"\"")
                csv += "\(key),\"\(netType)\",\"\(netEscaped)\",\(d.physical.received),\(d.physical.sent),\(d.physical.total),\(Int(d.monitoredSeconds))\n"
                for (name, b) in d.processes.sorted(by: { $0.value.total > $1.value.total }) {
                    let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
                    csv += "\(key),\"\(netEscaped)\",\"\(escaped)\",\(b.received),\(b.sent),\(b.total),\n"
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

    private static func checkIsRelay(name: String, displayName: String) -> Bool {
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

    private static func runCommand(_ path: String, _ arguments: [String]) -> (text: String, success: Bool) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env

        do {
            try process.run()
        } catch {
            return ("", false)
        }

        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
        }

        process.waitUntilExit()
        group.wait()

        let outputText = String(decoding: stdoutData, as: UTF8.self)
        return (outputText, process.terminationStatus == 0)
    }

    // MARK: - Parsers

    private static func parseProcesses(_ text: String) -> [String: TrafficProcessCounter] {
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

    private static func parseInterfaces(_ text: String) -> [String: TrafficBytes] {
        var result: [String: TrafficBytes] = [:]
        for line in text.split(separator: "\n") {
            let values = line.split(whereSeparator: { $0.isWhitespace })
            guard values.count >= 10,
                  values[0].hasPrefix("en"),
                  values[2].hasPrefix("<Link#"),
                  let received = UInt64(values[6]),
                  let sent = UInt64(values[9]) else { continue }
            let ifName = String(values[0])
            result[ifName] = TrafficBytes(received: received, sent: sent)
        }
        return result
    }

    private static func parseProcessPaths(_ text: String) -> [String: (name: String, path: String)] {
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
