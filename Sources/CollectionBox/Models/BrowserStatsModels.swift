import Foundation
import AppKit
import SwiftUI

// MARK: - Browser Kind & Filter

public enum BrowserKind: String, CaseIterable, Identifiable, Sendable {
    case dia = "Dia"
    case chrome = "Chrome"

    public var id: String { rawValue }

    public var tintColor: Color {
        switch self {
        case .dia: return Color.purple
        case .chrome: return Color.blue
        }
    }

    public var icon: String {
        switch self {
        case .dia: return "sparkles"
        case .chrome: return "globe"
        }
    }
}

public enum BrowserSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case dia = "Dia"
    case chrome = "Chrome"

    public var id: String { rawValue }

    public func matches(_ kind: BrowserKind) -> Bool {
        switch self {
        case .all: return true
        case .dia: return kind == .dia
        case .chrome: return kind == .chrome
        }
    }
}

// MARK: - Time Range

public enum BrowserTimeRange: String, CaseIterable, Identifiable, Sendable {
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

// MARK: - Discovered Browser Profile

public struct BrowserProfileInfo: Identifiable, Sendable {
    public var id: String { "\(browser.rawValue):\(profileName)" }
    public let browser: BrowserKind
    public let profileName: String
    public let historyPath: String
    public let faviconsPath: String?
    public let lastModified: Date

    public init(
        browser: BrowserKind,
        profileName: String,
        historyPath: String,
        faviconsPath: String?,
        lastModified: Date
    ) {
        self.browser = browser
        self.profileName = profileName
        self.historyPath = historyPath
        self.faviconsPath = faviconsPath
        self.lastModified = lastModified
    }
}

// MARK: - Domain Stat

public struct BrowserDomainStat: Identifiable, Sendable {
    public var id: String { domain }
    public let domain: String
    public let visitCount: Int
    public let totalDurationSeconds: Double
    public let percentage: Double

    public init(
        domain: String,
        visitCount: Int,
        totalDurationSeconds: Double,
        percentage: Double
    ) {
        self.domain = domain
        self.visitCount = visitCount
        self.totalDurationSeconds = totalDurationSeconds
        self.percentage = percentage
    }
}

// MARK: - Hourly Stat

public struct BrowserHourlyStat: Identifiable, Sendable {
    public var id: Int { hour }
    public let hour: Int
    public let visitCount: Int
    public let durationSeconds: Double

    public init(hour: Int, visitCount: Int, durationSeconds: Double) {
        self.hour = hour
        self.visitCount = visitCount
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Frequent Page

public struct BrowserFrequentPage: Identifiable, Sendable {
    public let id: String // normalized URL
    public let url: String
    public let title: String
    public let domain: String
    public let visitCount: Int
    public let totalDurationSeconds: Double
    public let lastVisitDate: Date
    public let browser: BrowserKind

    public init(
        id: String,
        url: String,
        title: String,
        domain: String,
        visitCount: Int,
        totalDurationSeconds: Double,
        lastVisitDate: Date,
        browser: BrowserKind
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.domain = domain
        self.visitCount = visitCount
        self.totalDurationSeconds = totalDurationSeconds
        self.lastVisitDate = lastVisitDate
        self.browser = browser
    }
}

// MARK: - Aggregated Stats Data

public struct BrowserStatsData: Sendable {
    public let totalVisits: Int
    public let todayVisits: Int
    public let rangeVisits: Int
    public let avgDailyVisits: Int
    public let rangeDurationSeconds: Double
    public let todayDurationSeconds: Double
    public let uniqueDomainsCount: Int
    public let diaVisits: Int
    public let chromeVisits: Int
    public let topDomains: [BrowserDomainStat]
    public let hourlyStats: [BrowserHourlyStat]
    public let frequentPages: [BrowserFrequentPage]
    public let activeProfiles: [BrowserProfileInfo]
    public let faviconsByDomain: [String: Data]

    public init(
        totalVisits: Int,
        todayVisits: Int,
        rangeVisits: Int,
        avgDailyVisits: Int,
        rangeDurationSeconds: Double,
        todayDurationSeconds: Double,
        uniqueDomainsCount: Int,
        diaVisits: Int,
        chromeVisits: Int,
        topDomains: [BrowserDomainStat],
        hourlyStats: [BrowserHourlyStat],
        frequentPages: [BrowserFrequentPage],
        activeProfiles: [BrowserProfileInfo],
        faviconsByDomain: [String: Data]
    ) {
        self.totalVisits = totalVisits
        self.todayVisits = todayVisits
        self.rangeVisits = rangeVisits
        self.avgDailyVisits = avgDailyVisits
        self.rangeDurationSeconds = rangeDurationSeconds
        self.todayDurationSeconds = todayDurationSeconds
        self.uniqueDomainsCount = uniqueDomainsCount
        self.diaVisits = diaVisits
        self.chromeVisits = chromeVisits
        self.topDomains = topDomains
        self.hourlyStats = hourlyStats
        self.frequentPages = frequentPages
        self.activeProfiles = activeProfiles
        self.faviconsByDomain = faviconsByDomain
    }
}
