import Foundation
import AppKit

/// Byte counter representing inbound and outbound traffic.
public struct TrafficBytes: Codable, Equatable, Sendable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0
    public var total: UInt64 { received + sent }

    public init(received: UInt64 = 0, sent: UInt64 = 0) {
        self.received = received
        self.sent = sent
    }

    public mutating func add(_ other: TrafficBytes) {
        received += other.received
        sent += other.sent
    }

    public func difference(from old: TrafficBytes) -> TrafficBytes {
        TrafficBytes(
            received: received >= old.received ? received - old.received : 0,
            sent: sent >= old.sent ? sent - old.sent : 0
        )
    }

    /// Formats raw bytes into a human-readable string (GB, MB, KB, B).
    public static func format(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            return String(format: "%.2f GB", value / 1_073_741_824.0)
        } else if value >= 1_048_576 {
            return String(format: "%.2f MB", value / 1_048_576.0)
        } else if value >= 1_024 {
            return String(format: "%.1f KB", value / 1_024.0)
        } else {
            return "\(bytes) B"
        }
    }

    /// Formats a speed rate in bytes per second.
    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_073_741_824 {
            return String(format: "%.2f GB/s", bytesPerSecond / 1_073_741_824.0)
        } else if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576.0)
        } else if bytesPerSecond >= 1_024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1_024.0)
        } else {
            return "\(Int(bytesPerSecond)) B/s"
        }
    }
}

/// Raw counter parsed from nettop.
public struct TrafficProcessCounter: Codable, Sendable {
    public var name: String
    public var bytes: TrafficBytes

    public init(name: String, bytes: TrafficBytes) {
        self.name = name
        self.bytes = bytes
    }
}

/// Aggregated records for a single calendar day.
public struct TrafficDayRecord: Codable, Sendable {
    public var physical: TrafficBytes = TrafficBytes()
    public var processes: [String: TrafficBytes] = [:]
    public var hourly: [Int: TrafficBytes] = [:]
    public var hourlyProcesses: [Int: [String: TrafficBytes]] = [:]
    public var monitoredSeconds: Double = 0

    public init(
        physical: TrafficBytes = TrafficBytes(),
        processes: [String: TrafficBytes] = [:],
        hourly: [Int: TrafficBytes] = [:],
        hourlyProcesses: [Int: [String: TrafficBytes]] = [:],
        monitoredSeconds: Double = 0
    ) {
        self.physical = physical
        self.processes = processes
        self.hourly = hourly
        self.hourlyProcesses = hourlyProcesses
        self.monitoredSeconds = monitoredSeconds
    }

    enum CodingKeys: String, CodingKey {
        case physical
        case processes
        case hourly
        case hourlyProcesses
        case monitoredSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.physical = try container.decodeIfPresent(TrafficBytes.self, forKey: .physical) ?? TrafficBytes()
        self.processes = try container.decodeIfPresent([String: TrafficBytes].self, forKey: .processes) ?? [:]
        self.hourly = try container.decodeIfPresent([Int: TrafficBytes].self, forKey: .hourly) ?? [:]
        self.hourlyProcesses = try container.decodeIfPresent([Int: [String: TrafficBytes]].self, forKey: .hourlyProcesses) ?? [:]
        self.monitoredSeconds = try container.decodeIfPresent(Double.self, forKey: .monitoredSeconds) ?? 0
    }
}

/// Hardware network type classification.
public enum TrafficNetworkType: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "all"
    case wifi = "wifi"
    case ethernet = "ethernet"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "全部网络"
        case .wifi: return "Wi-Fi 无线"
        case .ethernet: return "有线网卡"
        }
    }

    public var icon: String {
        switch self {
        case .all: return "network"
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        }
    }
}

/// Network context info (SSID or interface category).
public struct TrafficNetworkContext: Equatable, Sendable {
    public var key: String
    public var name: String
    public var type: TrafficNetworkType
    public var identified: Bool
    public var isHotspot: Bool

    public init(
        key: String,
        name: String,
        type: TrafficNetworkType = .all,
        identified: Bool = false,
        isHotspot: Bool = false
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.identified = identified
        self.isHotspot = isHotspot
    }

    public static let all = TrafficNetworkContext(key: "__all__", name: "全部网络", type: .all, identified: false, isHotspot: false)
}

/// Historical traffic grouped by a specific network (e.g. Wi-Fi SSID or Wired Ethernet).
public struct TrafficNetworkHistory: Codable, Sendable {
    public var name: String
    public var type: String?
    public var days: [String: TrafficDayRecord] = [:]

    public init(name: String, type: String? = nil, days: [String: TrafficDayRecord] = [:]) {
        self.name = name
        self.type = type
        self.days = days
    }
}

/// Persistent ledger of all recorded traffic across days and networks.
public struct TrafficLedger: Codable, Sendable {
    public var version: Int = 2
    public var firstStarted: Date
    public var days: [String: TrafficDayRecord] = [:]
    public var networks: [String: TrafficNetworkHistory] = [:]

    public init(firstStarted: Date = Date()) {
        self.firstStarted = firstStarted
    }

    public mutating func clearAll() {
        days.removeAll()
        networks.removeAll()
        firstStarted = Date()
    }

    public mutating func clear(day: String) {
        days.removeValue(forKey: day)
        for key in networks.keys {
            networks[key]?.days.removeValue(forKey: day)
        }
    }

    public mutating func add(
        day: String,
        hour: Int,
        physical: TrafficBytes,
        processes: [String: TrafficBytes],
        seconds: Double,
        network: TrafficNetworkContext = .all
    ) {
        if network.key == "__all__" {
            var record = days[day] ?? TrafficDayRecord()
            record.physical.add(physical)
            record.monitoredSeconds += seconds

            var hourBytes = record.hourly[hour] ?? TrafficBytes()
            hourBytes.add(physical)
            record.hourly[hour] = hourBytes

            var hourProcs = record.hourlyProcesses[hour] ?? [:]
            for (name, value) in processes {
                var b = record.processes[name] ?? TrafficBytes()
                b.add(value)
                record.processes[name] = b

                var hb = hourProcs[name] ?? TrafficBytes()
                hb.add(value)
                hourProcs[name] = hb
            }
            record.hourlyProcesses[hour] = hourProcs
            days[day] = record
            return
        }

        // Group by network key (wifi:SSID or ethernet:有线网卡)
        var history = networks[network.key] ?? TrafficNetworkHistory(name: network.name, type: network.type.rawValue)
        history.name = network.name
        history.type = network.type.rawValue
        var netDay = history.days[day] ?? TrafficDayRecord()
        netDay.physical.add(physical)
        netDay.monitoredSeconds += seconds

        var netHourBytes = netDay.hourly[hour] ?? TrafficBytes()
        netHourBytes.add(physical)
        netDay.hourly[hour] = netHourBytes

        var netHourProcs = netDay.hourlyProcesses[hour] ?? [:]
        for (name, value) in processes {
            var b = netDay.processes[name] ?? TrafficBytes()
            b.add(value)
            netDay.processes[name] = b

            var hb = netHourProcs[name] ?? TrafficBytes()
            hb.add(value)
            netHourProcs[name] = hb
        }
        netDay.hourlyProcesses[hour] = netHourProcs
        history.days[day] = netDay
        networks[network.key] = history
    }

    public func sum(keys: [String], networkName: String? = nil) -> TrafficDayRecord {
        var result = TrafficDayRecord()
        let sources: [[String: TrafficDayRecord]]
        if let selected = networkName, selected != "__all__" {
            sources = networks.values.filter { $0.name == selected }.map(\.days)
        } else {
            sources = [days]
        }

        for source in sources {
            for key in keys {
                guard let day = source[key] else { continue }
                result.physical.add(day.physical)
                result.monitoredSeconds += day.monitoredSeconds
                for (h, hb) in day.hourly {
                    var cur = result.hourly[h] ?? TrafficBytes()
                    cur.add(hb)
                    result.hourly[h] = cur
                }
                for (name, bytes) in day.processes {
                    var value = result.processes[name] ?? TrafficBytes()
                    value.add(bytes)
                    result.processes[name] = value
                }
                for (h, hp) in day.hourlyProcesses {
                    var curProcs = result.hourlyProcesses[h] ?? [:]
                    for (name, bytes) in hp {
                        var curVal = curProcs[name] ?? TrafficBytes()
                        curVal.add(bytes)
                        curProcs[name] = curVal
                    }
                    result.hourlyProcesses[h] = curProcs
                }
            }
        }
        return result
    }
}

/// Time period filter for traffic reporting.
public enum TrafficPeriod: Int, CaseIterable, Identifiable, Sendable {
    case today = 0
    case yesterday = 1
    case month = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .month: return "本月"
        }
    }
}

/// Sort column for process traffic list (PID column removed).
public enum TrafficSortField: String, CaseIterable, Identifiable, Sendable {
    case total = "总流量"
    case download = "下载量"
    case upload = "上传量"
    case name = "进程 / 应用"

    public var id: String { rawValue }
}

/// UI presentation model for a process item in the traffic table.
public struct TrafficProcessItem: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var pid: pid_t
    public var appBundlePath: String?
    public var bytes: TrafficBytes
    public var isRelay: Bool

    public init(
        name: String,
        displayName: String,
        pid: pid_t = 0,
        appBundlePath: String? = nil,
        bytes: TrafficBytes,
        isRelay: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.pid = pid
        self.appBundlePath = appBundlePath
        self.bytes = bytes
        self.isRelay = isRelay
    }
}

/// Helper for calendar day keys.
public enum TrafficDateKeys {
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    public static func keys(period: TrafficPeriod, now: Date, available: [String], calendar: Calendar = .current) -> [String] {
        switch period {
        case .today:
            return [day(now, calendar: calendar)]
        case .yesterday:
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
                return [day(yesterday, calendar: calendar)]
            }
            return [day(now, calendar: calendar)]
        case .month:
            let prefix = String(day(now, calendar: calendar).prefix(7))
            return available.filter { $0.hasPrefix(prefix) }
        }
    }
}
