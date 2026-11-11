import Foundation
import AppKit
import SQLite3
import SwiftUI

@MainActor
public final class ClipboardStatsService: ObservableObject {
    public static let shared = ClipboardStatsService()

    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var dbPath: String?
    @Published public private(set) var stats: ClipboardStatsData?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastRefreshTime: Date?
    @Published public private(set) var ignoredRepeatedIDs: Set<Int64>
    @Published public var selectedRange: ClipboardTimeRange = .days7 {
        didSet {
            if oldValue != selectedRange {
                refresh()
            }
        }
    }

    private static let ignoredIDsDefaultsKey = "Pinner.clipboardStats.ignoredRepeatedIDs"
    private var appInfoCache: [String: (name: String, icon: NSImage?)] = [:]
    private var loadGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    public init() {
        let saved = (UserDefaults.standard.array(forKey: Self.ignoredIDsDefaultsKey) as? [NSNumber])?.map(\.int64Value) ?? []
        self.ignoredRepeatedIDs = Set(saved)
        self.dbPath = Self.locateDatabasePath()
        self.isAvailable = (dbPath != nil)
    }

    // MARK: - Ignored Repeated Items

    public func ignoreRepeatedItem(id: Int64) {
        ignoredRepeatedIDs.insert(id)
        UserDefaults.standard.set(ignoredRepeatedIDs.map { NSNumber(value: $0) }, forKey: Self.ignoredIDsDefaultsKey)
    }

    public func resetIgnoredRepeatedItems() {
        ignoredRepeatedIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.ignoredIDsDefaultsKey)
    }

    // MARK: - Path Resolution

    public static func locateDatabasePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let groupContainers = (home as NSString).appendingPathComponent("Library/Group Containers")

        // 1. Check default known team identifier container
        let standardPath = (groupContainers as NSString)
            .appendingPathComponent("KAQ3M6FSM7.app.pastenow.PasteNow/Documents/PasteNow.sqlite")
        if FileManager.default.fileExists(atPath: standardPath) {
            return standardPath
        }

        // 2. Discover dynamically in Group Containers
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: groupContainers) else {
            return nil
        }
        for item in items where item.hasSuffix(".app.pastenow.PasteNow") {
            let candidate = (groupContainers as NSString)
                .appendingPathComponent("\(item)/Documents/PasteNow.sqlite")
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Refresh

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.loadStats()
        }
    }

    public func loadStats() async {
        loadGeneration &+= 1
        let gen = loadGeneration

        guard let path = dbPath ?? Self.locateDatabasePath() else {
            self.isAvailable = false
            self.stats = nil
            self.isLoading = false
            return
        }

        self.dbPath = path
        self.isAvailable = true
        self.isLoading = true

        let range = self.selectedRange

        let data = await Task.detached(priority: .userInitiated) { () -> ClipboardStatsData? in
            guard !Task.isCancelled else { return nil }
            return Self.queryDatabase(at: path, range: range)
        }.value

        guard gen == loadGeneration else { return }
        self.isLoading = false
        if let data {
            self.stats = data
            self.lastRefreshTime = Date()
        }
    }

    // MARK: - App Info Resolution

    public func appInfo(for bundleId: String) -> (name: String, icon: NSImage?) {
        if let cached = appInfoCache[bundleId] {
            return cached
        }

        var appName = bundleId
        var appIcon: NSImage? = nil

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            appName = FileManager.default.displayName(atPath: url.path)
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            // Friendly fallback names for common tools
            let lower = bundleId.lowercased()
            if lower.contains("antigravity") {
                appName = "Antigravity"
            } else if lower.contains("zcode") {
                appName = "ZCode"
            } else if lower.contains("dia") {
                appName = "Dia"
            } else if lower.contains("ishot") {
                appName = "iShot"
            } else if lower.contains("pinner") {
                appName = "Pinner"
            } else if lower.contains("wechat") {
                appName = "微信"
            } else if lower.contains("codex") {
                appName = "Codex"
            } else if lower.contains("workbuddy") {
                appName = "WorkBuddy"
            } else if lower.contains("finder") {
                appName = "访达"
            } else {
                appName = bundleId.components(separatedBy: ".").last ?? bundleId
            }
        }

        let result = (appName, appIcon)
        appInfoCache[bundleId] = result
        return result
    }

    // MARK: - Database Queries

    nonisolated private static func openReadOnlyDatabase(at path: String) -> OpaquePointer? {
        for immutable in [false, true] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            let target = immutable ? "\(URL(fileURLWithPath: path).absoluteString)?immutable=1" : path
            guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            sqlite3_busy_timeout(db, 3000)
            var probe: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1 FROM ZPASTEITEM LIMIT 1", -1, &probe, nil) == SQLITE_OK {
                if let probe { sqlite3_finalize(probe) }
                return db
            }
            if let probe { sqlite3_finalize(probe) }
            sqlite3_close(db)
        }
        return nil
    }

    nonisolated static func queryDatabase(at path: String, range: ClipboardTimeRange) -> ClipboardStatsData? {
        guard let db = openReadOnlyDatabase(at: path) else {
            return nil
        }
        defer { sqlite3_close(db) }

        // Time references (Apple reference date: seconds since 2001-01-01)
        let now = Date()
        let calendar = Calendar.current
        let todayStartRef = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate

        let rangeStartRef: Double
        switch range {
        case .today:
            rangeStartRef = todayStartRef
        case .days7:
            rangeStartRef = now.addingTimeInterval(-7 * 86400).timeIntervalSinceReferenceDate
        case .days30:
            rangeStartRef = now.addingTimeInterval(-30 * 86400).timeIntervalSinceReferenceDate
        case .all:
            rangeStartRef = 0
        }

        // 2. Counts
        let totalCount = queryInt(db, "SELECT COUNT(*) FROM ZPASTEITEM")
        let todayCount = queryInt(db, "SELECT COUNT(*) FROM ZPASTEITEM WHERE ZTIMESTAMP >= ?", [todayStartRef])
        let rangeCount: Int
        if range == .all {
            rangeCount = totalCount
        } else {
            rangeCount = queryInt(db, "SELECT COUNT(*) FROM ZPASTEITEM WHERE ZTIMESTAMP >= ?", [rangeStartRef])
        }

        // Daily average
        let daySpan: Int
        if let fixedDays = range.days {
            daySpan = max(1, fixedDays)
        } else if let minTs = queryOptionalDouble(db, "SELECT MIN(ZTIMESTAMP) FROM ZPASTEITEM WHERE ZTIMESTAMP > 0") {
            let elapsedDays = Int(ceil((now.timeIntervalSinceReferenceDate - minTs) / 86400.0))
            daySpan = max(1, elapsedDays)
        } else {
            daySpan = 1
        }
        let avgDailyCount = rangeCount / daySpan

        // 3. Content Types
        var typeCounts: [ClipboardContentType: Int] = [
            .text: 0, .image: 0, .url: 0, .file: 0, .other: 0
        ]
        let typeSql = range == .all
            ? "SELECT ZBASEUNIFORMTYPE, COUNT(*) FROM ZPASTEITEM GROUP BY ZBASEUNIFORMTYPE"
            : "SELECT ZBASEUNIFORMTYPE, COUNT(*) FROM ZPASTEITEM WHERE ZTIMESTAMP >= ? GROUP BY ZBASEUNIFORMTYPE"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, typeSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            if range != .all {
                sqlite3_bind_double(stmt, 1, rangeStartRef)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ut = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                let c = Int(sqlite3_column_int64(stmt, 1))
                let ct = ClipboardContentType.from(uniformType: ut)
                typeCounts[ct, default: 0] += c
            }
            sqlite3_finalize(stmt)
        }

        let typeTotal = max(1, rangeCount)
        let typeStats = ClipboardContentType.allCases.map { t in
            let c = typeCounts[t, default: 0]
            return ClipboardTypeStat(type: t, count: c, percentage: Double(c) / Double(typeTotal))
        }.sorted { $0.count > $1.count }

        // 4. Top Apps
        var topApps: [ClipboardAppStat] = []
        let appSql = range == .all
            ? "SELECT ZAPPBUNDLEID, COUNT(*) FROM ZPASTEITEM WHERE ZAPPBUNDLEID IS NOT NULL GROUP BY ZAPPBUNDLEID ORDER BY COUNT(*) DESC LIMIT 8"
            : "SELECT ZAPPBUNDLEID, COUNT(*) FROM ZPASTEITEM WHERE ZTIMESTAMP >= ? AND ZAPPBUNDLEID IS NOT NULL GROUP BY ZAPPBUNDLEID ORDER BY COUNT(*) DESC LIMIT 8"
        if sqlite3_prepare_v2(db, appSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            if range != .all {
                sqlite3_bind_double(stmt, 1, rangeStartRef)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let bPtr = sqlite3_column_text(stmt, 0) {
                    let bundleId = String(cString: bPtr)
                    let c = Int(sqlite3_column_int64(stmt, 1))
                    let pct = Double(c) / Double(typeTotal)
                    topApps.append(ClipboardAppStat(bundleId: bundleId, name: bundleId, count: c, percentage: pct))
                }
            }
            sqlite3_finalize(stmt)
        }

        // 5. Hourly Activity (0...23)
        var hourlyMap: [Int: Int] = [:]
        for h in 0...23 { hourlyMap[h] = 0 }
        let hourSql = range == .all
            ? "SELECT CAST(strftime('%H', datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime')) AS INTEGER) AS hr, COUNT(*) FROM ZPASTEITEM GROUP BY hr"
            : "SELECT CAST(strftime('%H', datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime')) AS INTEGER) AS hr, COUNT(*) FROM ZPASTEITEM WHERE ZTIMESTAMP >= ? GROUP BY hr"
        if sqlite3_prepare_v2(db, hourSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            if range != .all {
                sqlite3_bind_double(stmt, 1, rangeStartRef)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let hr = Int(sqlite3_column_int64(stmt, 0))
                let c = Int(sqlite3_column_int64(stmt, 1))
                if (0...23).contains(hr) {
                    hourlyMap[hr] = c
                }
            }
            sqlite3_finalize(stmt)
        }
        let hourlyStats = (0...23).map { ClipboardHourlyStat(hour: $0, count: hourlyMap[$0, default: 0]) }

        // 6. Daily Trends (last 14 days)
        var dailyTrends: [ClipboardDailyTrend] = []
        let trendDaysRef = now.addingTimeInterval(-14 * 86400).timeIntervalSinceReferenceDate
        let trendSql = """
        SELECT date(datetime(ZTIMESTAMP + 978307200, 'unixepoch', 'localtime')) AS dayStr, COUNT(*)
        FROM ZPASTEITEM
        WHERE ZTIMESTAMP >= ?
        GROUP BY dayStr
        ORDER BY dayStr ASC
        """
        if sqlite3_prepare_v2(db, trendSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            sqlite3_bind_double(stmt, 1, trendDaysRef)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let dPtr = sqlite3_column_text(stmt, 0) {
                    let dStr = String(cString: dPtr)
                    let c = Int(sqlite3_column_int64(stmt, 1))
                    let label = dStr.count >= 5 ? String(dStr.suffix(5)) : dStr
                    dailyTrends.append(ClipboardDailyTrend(dateString: dStr, count: c, label: label))
                }
            }
            sqlite3_finalize(stmt)
        }

        // 7. Top Repeated Items (ZCOPYCOUNT > 1)
        var topRepeated: [ClipboardRepeatedItem] = []
        let repSql = """
        SELECT Z_PK, ZTEXT, ZTITLE, ZBASEUNIFORMTYPE, ZAPPBUNDLEID, ZCOPYCOUNT, ZTIMESTAMP
        FROM ZPASTEITEM
        WHERE ZCOPYCOUNT > 1 AND ZTEXT IS NOT NULL AND length(trim(ZTEXT)) > 0
        ORDER BY ZCOPYCOUNT DESC
        LIMIT 50
        """
        if sqlite3_prepare_v2(db, repSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pk = sqlite3_column_int64(stmt, 0)
                let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let ut = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let bundle = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let copyCount = Int(sqlite3_column_int64(stmt, 5))
                let ts = sqlite3_column_double(stmt, 6)
                let date = Date(timeIntervalSinceReferenceDate: ts)

                let item = ClipboardRepeatedItem(
                    id: pk,
                    text: text,
                    title: title,
                    type: ClipboardContentType.from(uniformType: ut),
                    appBundleId: bundle,
                    appName: bundle,
                    copyCount: copyCount,
                    date: date
                )
                topRepeated.append(item)
            }
            sqlite3_finalize(stmt)
        }

        return ClipboardStatsData(
            totalCount: totalCount,
            todayCount: todayCount,
            rangeCount: rangeCount,
            avgDailyCount: avgDailyCount,
            typeStats: typeStats,
            topApps: topApps,
            hourlyStats: hourlyStats,
            dailyTrends: dailyTrends,
            topRepeated: topRepeated
        )
    }

    private nonisolated static func queryInt(_ db: OpaquePointer?, _ sql: String, _ doubleBinds: [Double] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in doubleBinds.enumerated() {
            sqlite3_bind_double(stmt, Int32(i + 1), v)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private nonisolated static func queryOptionalDouble(_ db: OpaquePointer?, _ sql: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            return sqlite3_column_double(stmt, 0)
        }
        return nil
    }
}
