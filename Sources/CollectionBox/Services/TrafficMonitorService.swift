import Foundation
import AppKit
import CoreWLAN
import Network

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

    // App icons cached by bundle path or app name
    @Published public private(set) var processIcons: [String: NSImage] = [:]

    private var timer: Timer?
    private var inFlight: Bool = false
    private var oldProcesses: [String: TrafficProcessCounter] = [:]
    private var oldInterfaces: [String: TrafficBytes] = [:]
    private var oldTime: Date?
    private var lastSaved: Date = .distantPast
    private var oldNetwork: TrafficNetworkContext?
    private var appPaths: [String: String] = [:]
    private var pidMapping: [String: (name: String, path: String)] = [:]
    private var activePIDs: [String: pid_t] = [:]

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.tienyeung.pinner.traffic.pathmonitor", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "com.tienyeung.pinner.traffic.sampling", qos: .utility)
    private let ledgerFileURL: URL
    private var storeWritable: Bool = true

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
            self?.oldTime = nil
            self?.sample()
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
        if let h = selectedHour {
            procSource = record.hourlyProcesses[h] ?? [:]
        } else {
            procSource = record.processes
        }

        for (name, bytes) in procSource {
            let path = appPaths[name]
            let displayName: String

            if let p = path, let enclosing = Self.findEnclosingAppPath(path: p) {
                displayName = URL(fileURLWithPath: enclosing).deletingPathExtension().lastPathComponent
            } else {
                displayName = name
            }

            let pid = activePIDs[name] ?? 0
            let isRelay = Self.checkIsRelay(name: name, displayName: displayName)

            items.append(
                TrafficProcessItem(
                    name: name,
                    displayName: displayName,
                    pid: pid,
                    appBundlePath: path,
                    bytes: bytes,
                    isRelay: isRelay
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

    public func startMonitoring() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        save()
    }

    public func togglePause() {
        isPaused.toggle()
        oldTime = nil
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
        oldInterfaces.removeAll()
        oldTime = nil
        save()
    }

    public func clearAllData() {
        ledger.clearAll()
        oldProcesses.removeAll()
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
                // -t external: 严格排除 loopback 回环 (127.0.0.1/lo0)，只统计实际外部物理网卡流量 (Wi-Fi / Ethernet)
                let procResult = Self.runCommand("/usr/bin/nettop", ["-t", "external", "-P", "-L", "1", "-n", "-J", "bytes_in,bytes_out"])
                let netResult = Self.runCommand("/usr/sbin/netstat", ["-ibn"])
                let psResult = Self.runCommand("/bin/ps", ["-axo", "pid=,comm="])
                let now = Date()

                DispatchQueue.main.async {
                    self?.applySampleResults(
                        proc: procResult,
                        net: netResult,
                        psOutput: psResult.text,
                        now: now,
                        network: samplingNetwork
                    )
                }
            }
        }
    }

    private func applySampleResults(
        proc: (text: String, success: Bool),
        net: (text: String, success: Bool),
        psOutput: String,
        now: Date,
        network: TrafficNetworkContext
    ) {
        inFlight = false
        guard !isPaused else {
            oldTime = nil
            return
        }

        let parsedProcesses = Self.parseProcesses(proc.text)
        let parsedInterfaces = Self.parseInterfaces(net.text)

        guard proc.success, !parsedProcesses.isEmpty, net.success, !parsedInterfaces.isEmpty else {
            statusMessage = "采集异常：无法获取网络计数器"
            currentDownloadRate = 0
            currentUploadRate = 0
            oldTime = nil
            return
        }

        let mapping = Self.parseProcessPaths(psOutput)
        for (pidStr, item) in mapping {
            pidMapping[pidStr] = item
            if let pidNum = pid_t(pidStr) {
                activePIDs[item.name] = pidNum
            }
            if item.path.contains(".app") {
                appPaths[item.name] = item.path
            }
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

                let dayKey = TrafficDateKeys.day(now)
                let currentHour = Calendar.current.component(.hour, from: now)

                // 1. All networks aggregate
                ledger.add(
                    day: dayKey,
                    hour: currentHour,
                    physical: physical,
                    processes: processDeltas,
                    seconds: interval,
                    network: .all
                )

                // 2. Wi-Fi network stream
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
                        processes: wifiBytes.total >= ethernetBytes.total ? processDeltas : [:],
                        seconds: interval,
                        network: wifiCtx
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
                        processes: ethernetBytes.total > wifiBytes.total ? processDeltas : [:],
                        seconds: interval,
                        network: ethCtx
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
        oldInterfaces = parsedInterfaces
        oldTime = now
        oldNetwork = network
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
        guard storeWritable else { return }
        do {
            try FileManager.default.createDirectory(
                at: ledgerFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: ledgerFileURL, options: .atomic)
        } catch {
            statusMessage = "历史数据写入异常: \(error.localizedDescription)"
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
            "qv2ray", "nekoray", "dae", "snell"
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
