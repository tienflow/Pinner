import Foundation
import AppKit
import SwiftUI

// MARK: - Time Range

public enum ClipboardTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case days7 = "近 7 天"
    case days30 = "近 30 天"
    case all = "全部"

    public var id: String { rawValue }

    public var days: Int? {
        switch self {
        case .today: return 1
        case .days7: return 7
        case .days30: return 30
        case .all: return nil
        }
    }
}

// MARK: - Content Type

public enum ClipboardContentType: String, CaseIterable, Identifiable, Sendable {
    case text = "文本"
    case image = "图片"
    case url = "链接"
    case file = "文件"
    case other = "其他"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .url: return "link"
        case .file: return "doc"
        case .other: return "square.stack"
        }
    }

    public var tintColor: Color {
        switch self {
        case .text: return Color.blue
        case .image: return Color.purple
        case .url: return Color.teal
        case .file: return Color.orange
        case .other: return Color.secondary
        }
    }

    public static func from(uniformType: String?) -> ClipboardContentType {
        guard let ut = uniformType?.lowercased() else { return .other }
        if ut.contains("image") || ut.contains("png") || ut.contains("tiff") || ut.contains("jpeg") {
            return .image
        } else if ut.contains("url") && !ut.contains("file") {
            return .url
        } else if ut.contains("file") {
            return .file
        } else if ut.contains("text") || ut.contains("string") || ut.contains("rtf") {
            return .text
        } else {
            return .other
        }
    }
}

// MARK: - Type Stat

public struct ClipboardTypeStat: Identifiable, Sendable {
    public var id: String { type.rawValue }
    public let type: ClipboardContentType
    public let count: Int
    public let percentage: Double

    public init(type: ClipboardContentType, count: Int, percentage: Double) {
        self.type = type
        self.count = count
        self.percentage = percentage
    }
}

// MARK: - App Stat

public struct ClipboardAppStat: Identifiable, Sendable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String
    public let count: Int
    public let percentage: Double
    public let icon: NSImage?

    public init(bundleId: String, name: String, count: Int, percentage: Double, icon: NSImage? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.count = count
        self.percentage = percentage
        self.icon = icon
    }
}

// MARK: - Hourly Stat

public struct ClipboardHourlyStat: Identifiable, Sendable {
    public var id: Int { hour }
    public let hour: Int // 0...23
    public let count: Int

    public init(hour: Int, count: Int) {
        self.hour = hour
        self.count = count
    }
}

// MARK: - Daily Trend

public struct ClipboardDailyTrend: Identifiable, Sendable {
    public var id: String { dateString }
    public let dateString: String // YYYY-MM-DD
    public let count: Int
    public let label: String      // e.g. "11-10"

    public init(dateString: String, count: Int, label: String) {
        self.dateString = dateString
        self.count = count
        self.label = label
    }
}

// MARK: - Repeated Item

public struct ClipboardRepeatedItem: Identifiable, Sendable {
    public let id: Int64
    public let text: String
    public let title: String?
    public let type: ClipboardContentType
    public let appBundleId: String?
    public let appName: String?
    public let copyCount: Int
    public let date: Date

    public init(
        id: Int64,
        text: String,
        title: String?,
        type: ClipboardContentType,
        appBundleId: String?,
        appName: String?,
        copyCount: Int,
        date: Date
    ) {
        self.id = id
        self.text = text
        self.title = title
        self.type = type
        self.appBundleId = appBundleId
        self.appName = appName
        self.copyCount = copyCount
        self.date = date
    }
}

// MARK: - Aggregate Stats Data

public struct ClipboardStatsData: Sendable {
    public let totalCount: Int
    public let todayCount: Int
    public let rangeCount: Int
    public let avgDailyCount: Int
    public let typeStats: [ClipboardTypeStat]
    public let topApps: [ClipboardAppStat]
    public let hourlyStats: [ClipboardHourlyStat]
    public let dailyTrends: [ClipboardDailyTrend]
    public let topRepeated: [ClipboardRepeatedItem]

    public init(
        totalCount: Int,
        todayCount: Int,
        rangeCount: Int,
        avgDailyCount: Int,
        typeStats: [ClipboardTypeStat],
        topApps: [ClipboardAppStat],
        hourlyStats: [ClipboardHourlyStat],
        dailyTrends: [ClipboardDailyTrend],
        topRepeated: [ClipboardRepeatedItem]
    ) {
        self.totalCount = totalCount
        self.todayCount = todayCount
        self.rangeCount = rangeCount
        self.avgDailyCount = avgDailyCount
        self.typeStats = typeStats
        self.topApps = topApps
        self.hourlyStats = hourlyStats
        self.dailyTrends = dailyTrends
        self.topRepeated = topRepeated
    }
}
