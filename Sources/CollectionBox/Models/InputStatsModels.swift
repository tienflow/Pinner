import Foundation

// MARK: - Hourly Bucket

public struct HourlyInputBucket: Codable, Identifiable, Sendable {
    public var id: Int { hour }
    public var hour: Int           // 0...23
    public var keyCount: Int
    public var clickCount: Int
    public var distanceMeters: Double

    public init(hour: Int, keyCount: Int = 0, clickCount: Int = 0, distanceMeters: Double = 0.0) {
        self.hour = hour
        self.keyCount = keyCount
        self.clickCount = clickCount
        self.distanceMeters = distanceMeters
    }
}

// MARK: - App Input Stats

public struct AppInputStats: Codable, Identifiable, Sendable {
    public var id: String { bundleId.isEmpty ? appName : bundleId }
    public var bundleId: String
    public var appName: String
    public var keyCount: Int
    public var clickCount: Int
    public var scrollDistancePixels: Double

    public init(
        bundleId: String,
        appName: String,
        keyCount: Int = 0,
        clickCount: Int = 0,
        scrollDistancePixels: Double = 0.0
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.keyCount = keyCount
        self.clickCount = clickCount
        self.scrollDistancePixels = scrollDistancePixels
    }

    enum CodingKeys: String, CodingKey {
        case bundleId, appName, keyCount, clickCount, scrollDistancePixels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleId = try container.decode(String.self, forKey: .bundleId)
        self.appName = try container.decode(String.self, forKey: .appName)
        self.keyCount = try container.decode(Int.self, forKey: .keyCount)
        self.clickCount = try container.decode(Int.self, forKey: .clickCount)
        self.scrollDistancePixels = try container.decodeIfPresent(Double.self, forKey: .scrollDistancePixels) ?? 0.0
    }
}

// MARK: - Daily Input Stats

public struct DailyInputStats: Codable, Sendable {
    public var dateString: String                  // "YYYY-MM-DD"
    public var keyCount: Int
    public var leftClickCount: Int
    public var rightClickCount: Int
    public var middleClickCount: Int
    public var otherClickCount: Int
    public var mouseDistanceMeters: Double
    public var scrollDistancePixels: Double
    public var peakKPS: Double
    public var peakCPS: Double
    public var hourlyBuckets: [HourlyInputBucket]
    public var appStats: [String: AppInputStats]    // Keyed by bundleId/appName
    public var keyFrequencies: [String: Int]       // e.g. "Space": 340, "⌘C": 45

    public var totalClicks: Int {
        leftClickCount + rightClickCount + middleClickCount + otherClickCount
    }

    public init(
        dateString: String = "",
        keyCount: Int = 0,
        leftClickCount: Int = 0,
        rightClickCount: Int = 0,
        middleClickCount: Int = 0,
        otherClickCount: Int = 0,
        mouseDistanceMeters: Double = 0.0,
        scrollDistancePixels: Double = 0.0,
        peakKPS: Double = 0.0,
        peakCPS: Double = 0.0,
        hourlyBuckets: [HourlyInputBucket] = (0..<24).map { HourlyInputBucket(hour: $0) },
        appStats: [String: AppInputStats] = [:],
        keyFrequencies: [String: Int] = [:]
    ) {
        self.dateString = dateString
        self.keyCount = keyCount
        self.leftClickCount = leftClickCount
        self.rightClickCount = rightClickCount
        self.middleClickCount = middleClickCount
        self.otherClickCount = otherClickCount
        self.mouseDistanceMeters = mouseDistanceMeters
        self.scrollDistancePixels = scrollDistancePixels
        self.peakKPS = peakKPS
        self.peakCPS = peakCPS
        self.hourlyBuckets = hourlyBuckets.isEmpty ? (0..<24).map { HourlyInputBucket(hour: $0) } : hourlyBuckets
        self.appStats = appStats
        self.keyFrequencies = keyFrequencies
    }

    /// yyyy-MM-dd for the current day. Called from the key/mouse event hot
    /// path (date rollover check), so the formatter is cached rather than
    /// rebuilt per event — DateFormatter init costs 10-50 µs and this fires up
    /// to ~40×/second while typing.
    public static func todayDateString() -> String {
        cachedDateFormatter.string(from: Date())
    }

    private static let cachedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // Locale is irrelevant for a numeric-only pattern; pinning it keeps
        // output stable regardless of the user's region settings.
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Formatting Helpers

    public static func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        } else if meters >= 100 {
            return String(format: "%.1f m", meters)
        } else if meters >= 1 {
            return String(format: "%.1f m", meters)
        } else {
            return String(format: "%.0f cm", meters * 100)
        }
    }

    public static func formatScrollPixels(_ px: Double) -> String {
        if px >= 1_000_000 {
            return String(format: "%.2f MPx", px / 1_000_000)
        } else if px >= 10_000 {
            return String(format: "%.1f kPx", px / 1000)
        } else if px >= 1000 {
            return String(format: "%.1f kPx", px / 1000)
        } else {
            return String(format: "%.0f px", px)
        }
    }

    public static func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Daily Input Summary (for Multi-Day History)

public struct DailyInputSummary: Codable, Identifiable, Sendable {
    public var id: String { dateString }
    public var dateString: String // "YYYY-MM-DD"
    public var keyCount: Int
    public var clickCount: Int
    public var mouseDistanceMeters: Double
    public var scrollDistancePixels: Double
    public var appStats: [String: AppInputStats]

    public init(
        dateString: String,
        keyCount: Int = 0,
        clickCount: Int = 0,
        mouseDistanceMeters: Double = 0.0,
        scrollDistancePixels: Double = 0.0,
        appStats: [String: AppInputStats] = [:]
    ) {
        self.dateString = dateString
        self.keyCount = keyCount
        self.clickCount = clickCount
        self.mouseDistanceMeters = mouseDistanceMeters
        self.scrollDistancePixels = scrollDistancePixels
        self.appStats = appStats
    }

    public init(from daily: DailyInputStats) {
        self.dateString = daily.dateString
        self.keyCount = daily.keyCount
        self.clickCount = daily.totalClicks
        self.mouseDistanceMeters = daily.mouseDistanceMeters
        self.scrollDistancePixels = daily.scrollDistancePixels
        self.appStats = daily.appStats
    }

    enum CodingKeys: String, CodingKey {
        case dateString, keyCount, clickCount, mouseDistanceMeters, scrollDistancePixels, appStats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.dateString = try c.decode(String.self, forKey: .dateString)
        self.keyCount = try c.decode(Int.self, forKey: .keyCount)
        self.clickCount = try c.decode(Int.self, forKey: .clickCount)
        self.mouseDistanceMeters = try c.decode(Double.self, forKey: .mouseDistanceMeters)
        self.scrollDistancePixels = try c.decode(Double.self, forKey: .scrollDistancePixels)
        self.appStats = try c.decodeIfPresent([String: AppInputStats].self, forKey: .appStats) ?? [:]
    }

    public var shortDateLabel: String {
        let parts = dateString.split(separator: "-")
        if parts.count == 3 {
            return "\(parts[1])/\(parts[2])"
        }
        return dateString
    }
}

// MARK: - Metric Types & Chart Options

public enum InputMetricType: String, CaseIterable, Identifiable, Sendable {
    case keyboard = "键盘"
    case clicks = "点击"
    case distance = "移动"
    case scroll = "滚动"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .clicks: return "cursorarrow.rays"
        case .distance: return "computermouse.fill"
        case .scroll: return "arrow.up.and.down"
        }
    }

    public func value(from summary: DailyInputSummary) -> Double {
        switch self {
        case .keyboard: return Double(summary.keyCount)
        case .clicks: return Double(summary.clickCount)
        case .distance: return summary.mouseDistanceMeters
        case .scroll: return summary.scrollDistancePixels
        }
    }

    public func formatValue(_ val: Double) -> String {
        switch self {
        case .keyboard, .clicks:
            return DailyInputStats.formatNumber(Int(val))
        case .distance:
            return DailyInputStats.formatDistance(val)
        case .scroll:
            return DailyInputStats.formatScrollPixels(val)
        }
    }

    public func formatTotal(_ val: Double) -> String {
        switch self {
        case .keyboard, .clicks:
            if val >= 10_000 {
                return String(format: "%.1f k", val / 1000)
            } else {
                return DailyInputStats.formatNumber(Int(val))
            }
        case .distance:
            return DailyInputStats.formatDistance(val)
        case .scroll:
            return DailyInputStats.formatScrollPixels(val)
        }
    }
}

public enum InputChartType: String, CaseIterable, Identifiable, Sendable {
    case line = "折线"
    case bar = "柱状"
    public var id: String { rawValue }
}

public enum InputHistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case days7 = 7
    case days30 = 30
    public var id: Int { rawValue }
    public var label: String { "过去\(rawValue)天" }
}

public enum AppStatsRange: String, CaseIterable, Identifiable, Sendable {
    case today = "今天"
    case days7 = "过去7天"
    case days30 = "过去30天"
    case all = "全部"

    public var id: String { rawValue }
}

public enum AppSortMetric: String, CaseIterable, Identifiable, Sendable {
    case app = "应用"
    case keys = "键盘"
    case clicks = "点击"
    case scroll = "滚动"

    public var id: String { rawValue }
}

