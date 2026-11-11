import Foundation
import AppKit
import SQLite3

@MainActor
public final class BrowserStatsService: ObservableObject {
    public static let shared = BrowserStatsService()

    @Published public private(set) var isAvailable: Bool = false
    @Published public private(set) var detectedProfiles: [BrowserProfileInfo] = []
    @Published public private(set) var stats: BrowserStatsData?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastRefreshTime: Date?
    @Published public private(set) var ignoredFrequentURLs: Set<String>

    @Published public var selectedRange: BrowserTimeRange = .days7 {
        didSet {
            if oldValue != selectedRange {
                refresh()
            }
        }
    }

    @Published public var selectedSource: BrowserSourceFilter = .all {
        didSet {
            if oldValue != selectedSource {
                refresh()
            }
        }
    }

    private static let ignoredURLsDefaultsKey = "Pinner.browserStats.ignoredURLs"
    /// Chromium stores timestamps as microseconds since 1601-01-01.
    private nonisolated static let chromeEpochOffsetSeconds: Double = 11_644_473_600.0
    /// Cap single-visit dwell time at 30 minutes to prevent overnight open tabs from skewing stats.
    private nonisolated static let maxVisitDurationMicros: Int64 = 1_800_000_000

    private var faviconImageCache: [String: NSImage] = [:]
    private var loadGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    public init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.ignoredURLsDefaultsKey) ?? []
        self.ignoredFrequentURLs = Set(saved)
        let profiles = Self.discoverProfiles()
        self.detectedProfiles = profiles
        self.isAvailable = !profiles.isEmpty
    }

    // MARK: - Ignored Frequent Pages

    public func ignoreFrequentPage(url: String) {
        ignoredFrequentURLs.insert(url)
        UserDefaults.standard.set(Array(ignoredFrequentURLs), forKey: Self.ignoredURLsDefaultsKey)
    }

    public func resetIgnoredFrequentPages() {
        ignoredFrequentURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.ignoredURLsDefaultsKey)
    }

    // MARK: - Favicon Cache

    public func faviconImage(for domain: String) -> NSImage? {
        if let cached = faviconImageCache[domain] {
            return cached
        }
        guard let data = stats?.faviconsByDomain[domain],
              let img = NSImage(data: data) else {
            return nil
        }
        faviconImageCache[domain] = img
        return img
    }

    // MARK: - Profile Discovery

    public nonisolated static func discoverProfiles() -> [BrowserProfileInfo] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots: [(BrowserKind, String)] = [
            (.dia, (home as NSString).appendingPathComponent("Library/Application Support/Dia/User Data")),
            (.chrome, (home as NSString).appendingPathComponent("Library/Application Support/Google/Chrome"))
        ]

        var profiles: [BrowserProfileInfo] = []
        for (browser, root) in roots {
            guard let subdirs = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for sub in subdirs {
                // Only inspect standard Chromium profile directories
                guard sub == "Default" || sub.hasPrefix("Profile ") else { continue }
                let profileDir = (root as NSString).appendingPathComponent(sub)
                let historyPath = (profileDir as NSString).appendingPathComponent("History")
                guard fm.fileExists(atPath: historyPath) else { continue }

                let favPath = (profileDir as NSString).appendingPathComponent("Favicons")
                let attrs = try? fm.attributesOfItem(atPath: historyPath)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast

                profiles.append(BrowserProfileInfo(
                    browser: browser,
                    profileName: sub,
                    historyPath: historyPath,
                    faviconsPath: fm.fileExists(atPath: favPath) ? favPath : nil,
                    lastModified: mtime
                ))
            }
        }

        return profiles.sorted { $0.lastModified > $1.lastModified }
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

        let profiles = Self.discoverProfiles()
        self.detectedProfiles = profiles
        guard !profiles.isEmpty else {
            self.isAvailable = false
            self.stats = nil
            self.isLoading = false
            return
        }

        self.isAvailable = true
        self.isLoading = true

        let range = self.selectedRange
        let source = self.selectedSource

        let data = await Task.detached(priority: .userInitiated) { () -> BrowserStatsData? in
            guard !Task.isCancelled else { return nil }
            return Self.queryAllProfiles(profiles, range: range, source: source)
        }.value

        guard gen == loadGeneration else { return }
        self.isLoading = false
        if let data {
            self.stats = data
            self.lastRefreshTime = Date()
        }
    }

    // MARK: - Snapshot & SQLite Queries

    nonisolated static func queryAllProfiles(
        _ profiles: [BrowserProfileInfo],
        range: BrowserTimeRange,
        source: BrowserSourceFilter
    ) -> BrowserStatsData {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let todayStartUs = chromeMicros(from: todayStart)

        let rangeStartUs: Int64?
        switch range {
        case .today:
            rangeStartUs = todayStartUs
        case .days7:
            rangeStartUs = chromeMicros(from: now.addingTimeInterval(-7 * 86400))
        case .days30:
            rangeStartUs = chromeMicros(from: now.addingTimeInterval(-30 * 86400))
        case .all:
            rangeStartUs = nil
        }

        var totalVisits = 0
        var todayVisits = 0
        var todayDurationSeconds: Double = 0
        var rangeVisits = 0
        var rangeDurationSeconds: Double = 0
        var diaVisits = 0
        var chromeVisits = 0
        var minVisitUs: Int64? = nil

        struct DomainAgg {
            var count: Int = 0
            var durationSec: Double = 0
        }
        var domainMap: [String: DomainAgg] = [:]

        var hourlyCounts = [Int: Int]()
        var hourlyDurations = [Int: Double]()
        for h in 0...23 {
            hourlyCounts[h] = 0
            hourlyDurations[h] = 0
        }

        struct PageAgg {
            var url: String
            var title: String
            var domain: String
            var count: Int
            var durationSec: Double
            var lastVisitUs: Int64
            var browser: BrowserKind
        }
        var pageMap: [String: PageAgg] = [:]

        // Keep track of which favicon DBs exist for later lookup
        var faviconPaths: [String] = []

        for profile in profiles {
            if let fav = profile.faviconsPath {
                faviconPaths.append(fav)
            }
            guard let snapshot = openSnapshotDatabase(at: profile.historyPath) else { continue }
            defer { snapshot.cleanup() }
            let db = snapshot.db

            // 1. All-time & today baseline counts for browser split badge
            let profileTotal = queryInt(
                db,
                "SELECT COUNT(*) FROM visits v JOIN urls u ON v.url = u.id WHERE (u.url LIKE 'http://%' OR u.url LIKE 'https://%')"
            )
            let (profileTodayCount, profileTodayDurUs) = queryCountAndDuration(
                db,
                sql: """
                SELECT COUNT(*), COALESCE(SUM(MIN(MAX(v.visit_duration, 0), ?)), 0)
                FROM visits v
                JOIN urls u ON v.url = u.id
                WHERE v.visit_time >= ? AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                """,
                binds: [maxVisitDurationMicros, todayStartUs]
            )

            // Browser comparison counts reflect the currently selected time range
            let profileRangeVisits: Int
            if let startUs = rangeStartUs {
                profileRangeVisits = queryInt(
                    db,
                    "SELECT COUNT(*) FROM visits v JOIN urls u ON v.url = u.id WHERE v.visit_time >= ? AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')",
                    int64Binds: [startUs]
                )
            } else {
                profileRangeVisits = profileTotal
            }

            switch profile.browser {
            case .dia: diaVisits += profileRangeVisits
            case .chrome: chromeVisits += profileRangeVisits
            }

            guard source.matches(profile.browser) else { continue }

            totalVisits += profileTotal
            todayVisits += profileTodayCount
            todayDurationSeconds += Double(profileTodayDurUs) / 1_000_000.0

            // 2. Detailed visit rows within range
            let visitSql: String
            if rangeStartUs != nil {
                visitSql = """
                SELECT u.url, u.title, v.visit_time, v.visit_duration
                FROM visits v
                JOIN urls u ON v.url = u.id
                WHERE v.visit_time >= ? AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                """
            } else {
                visitSql = """
                SELECT u.url, u.title, v.visit_time, v.visit_duration
                FROM visits v
                JOIN urls u ON v.url = u.id
                WHERE (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
                """
            }

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, visitSql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                if let startUs = rangeStartUs {
                    sqlite3_bind_int64(stmt, 1, startUs)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let urlPtr = sqlite3_column_text(stmt, 0) else { continue }
                    let rawUrl = String(cString: urlPtr)
                    let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let visitTimeUs = sqlite3_column_int64(stmt, 2)
                    let rawDurUs = sqlite3_column_int64(stmt, 3)
                    let cappedDurSec = Double(min(max(0, rawDurUs), maxVisitDurationMicros)) / 1_000_000.0

                    rangeVisits += 1
                    rangeDurationSeconds += cappedDurSec
                    if visitTimeUs > 0 {
                        minVisitUs = minVisitUs.map { min($0, visitTimeUs) } ?? visitTimeUs
                    }

                    let visitDate = date(fromChromeMicros: visitTimeUs)
                    let hour = calendar.component(.hour, from: visitDate)
                    if (0...23).contains(hour) {
                        hourlyCounts[hour, default: 0] += 1
                        hourlyDurations[hour, default: 0] += cappedDurSec
                    }

                    guard let domain = extractDomain(from: rawUrl) else { continue }
                    var dAgg = domainMap[domain] ?? DomainAgg()
                    dAgg.count += 1
                    dAgg.durationSec += cappedDurSec
                    domainMap[domain] = dAgg

                    let normURL = normalizePageURL(rawUrl)
                    if var existing = pageMap[normURL] {
                        existing.count += 1
                        existing.durationSec += cappedDurSec
                        if visitTimeUs >= existing.lastVisitUs {
                            existing.lastVisitUs = visitTimeUs
                            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                existing.title = title
                            }
                            existing.browser = profile.browser
                        }
                        pageMap[normURL] = existing
                    } else {
                        pageMap[normURL] = PageAgg(
                            url: normURL,
                            title: title,
                            domain: domain,
                            count: 1,
                            durationSec: cappedDurSec,
                            lastVisitUs: visitTimeUs,
                            browser: profile.browser
                        )
                    }
                }
                sqlite3_finalize(stmt)
            }
        }

        let daySpan: Int
        if let fixedDays = range.days {
            daySpan = max(1, fixedDays)
        } else if let earliestUs = minVisitUs {
            let earliestDate = date(fromChromeMicros: earliestUs)
            let elapsedDays = Int(ceil(now.timeIntervalSince(earliestDate) / 86400.0))
            daySpan = max(1, elapsedDays)
        } else {
            daySpan = 1
        }
        let avgDailyVisits = rangeVisits / daySpan

        let totalVisitsDenom = max(1, rangeVisits)
        let topDomains = domainMap
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                return $0.value.durationSec > $1.value.durationSec
            }
            .prefix(8)
            .map { domain, agg in
                BrowserDomainStat(
                    domain: domain,
                    visitCount: agg.count,
                    totalDurationSeconds: agg.durationSec,
                    percentage: Double(agg.count) / Double(totalVisitsDenom)
                )
            }

        let hourlyStats = (0...23).map { h in
            BrowserHourlyStat(
                hour: h,
                visitCount: hourlyCounts[h, default: 0],
                durationSeconds: hourlyDurations[h, default: 0]
            )
        }

        let frequentPages = pageMap.values
            .filter { $0.count >= 2 }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.lastVisitUs > $1.lastVisitUs
            }
            .prefix(40)
            .map { agg in
                BrowserFrequentPage(
                    id: agg.url,
                    url: agg.url,
                    title: agg.title.isEmpty ? agg.url : agg.title,
                    domain: agg.domain,
                    visitCount: agg.count,
                    totalDurationSeconds: agg.durationSec,
                    lastVisitDate: date(fromChromeMicros: agg.lastVisitUs),
                    browser: agg.browser
                )
            }

        // Resolve favicons for visible domains
        var neededDomains = Set(topDomains.map(\.domain))
        for page in frequentPages.prefix(16) {
            neededDomains.insert(page.domain)
        }
        let faviconsByDomain = loadFavicons(for: neededDomains, from: faviconPaths)

        return BrowserStatsData(
            totalVisits: totalVisits,
            todayVisits: todayVisits,
            rangeVisits: rangeVisits,
            avgDailyVisits: avgDailyVisits,
            rangeDurationSeconds: rangeDurationSeconds,
            todayDurationSeconds: todayDurationSeconds,
            uniqueDomainsCount: domainMap.count,
            diaVisits: diaVisits,
            chromeVisits: chromeVisits,
            topDomains: topDomains,
            hourlyStats: hourlyStats,
            frequentPages: frequentPages,
            activeProfiles: profiles,
            faviconsByDomain: faviconsByDomain
        )
    }

    // MARK: - Favicons Lookup

    private nonisolated static func loadFavicons(for domains: Set<String>, from faviconPaths: [String]) -> [String: Data] {
        guard !domains.isEmpty else { return [:] }
        var remaining = domains
        var result: [String: Data] = [:]

        for favPath in faviconPaths {
            guard !remaining.isEmpty else { break }
            guard let snapshot = openSnapshotDatabase(at: favPath) else { continue }
            defer { snapshot.cleanup() }

            let sql = """
            SELECT fb.image_data
            FROM icon_mapping im
            JOIN favicon_bitmaps fb ON im.icon_id = fb.icon_id
            WHERE (im.page_url LIKE ? OR im.page_url LIKE ? OR im.page_url LIKE ?)
              AND fb.image_data IS NOT NULL
            ORDER BY ABS(fb.width - 32) ASC, fb.width DESC
            LIMIT 1
            """

            for domain in Array(remaining) {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(snapshot.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { continue }
                defer { sqlite3_finalize(stmt) }

                let p1 = "https://\(domain)/%"
                let p2 = "https://www.\(domain)/%"
                let p3 = "http://\(domain)/%"
                sqlite3_bind_text(stmt, 1, p1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 2, p2, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(stmt, 3, p3, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                if sqlite3_step(stmt) == SQLITE_ROW,
                   let bytes = sqlite3_column_blob(stmt, 0) {
                    let len = Int(sqlite3_column_bytes(stmt, 0))
                    if len > 0 {
                        result[domain] = Data(bytes: bytes, count: len)
                        remaining.remove(domain)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Snapshot Helper (Lock-Safe Read)

    private nonisolated static func openSnapshotDatabase(at path: String) -> (db: OpaquePointer, cleanup: () -> Void)? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("pinner-browser-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let baseName = (path as NSString).lastPathComponent
            let destPath = tempDir.appendingPathComponent(baseName).path
            try fm.copyItem(atPath: path, toPath: destPath)

            for suffix in ["-wal", "-shm"] {
                let sidecar = path + suffix
                if fm.fileExists(atPath: sidecar) {
                    try? fm.copyItem(atPath: sidecar, toPath: destPath + suffix)
                }
            }

            var db: OpaquePointer?
            if sqlite3_open_v2(destPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let opened = db {
                sqlite3_busy_timeout(opened, 2000)
                let cleanup: () -> Void = {
                    sqlite3_close(opened)
                    try? FileManager.default.removeItem(at: tempDir)
                }
                return (opened, cleanup)
            } else {
                if let db { sqlite3_close(db) }
                try? fm.removeItem(at: tempDir)
                return nil
            }
        } catch {
            try? fm.removeItem(at: tempDir)
            return nil
        }
    }

    // MARK: - SQLite & Formatting Helpers

    private nonisolated static func queryInt(_ db: OpaquePointer, _ sql: String, int64Binds: [Int64] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in int64Binds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), v)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private nonisolated static func queryCountAndDuration(
        _ db: OpaquePointer,
        sql: String,
        binds: [Int64]
    ) -> (Int, Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return (0, 0)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in binds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), v)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1))
        }
        return (0, 0)
    }

    private nonisolated static func chromeMicros(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + chromeEpochOffsetSeconds) * 1_000_000.0)
    }

    private nonisolated static func date(fromChromeMicros micros: Int64) -> Date {
        let unixSeconds = Double(micros) / 1_000_000.0 - chromeEpochOffsetSeconds
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private nonisolated static func extractDomain(from urlString: String) -> String? {
        guard let url = URL(string: urlString), var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        if let port = url.port, host == "localhost" || host == "127.0.0.1" {
            return "\(host):\(port)"
        }
        return host
    }

    private nonisolated static func normalizePageURL(_ raw: String) -> String {
        guard let idx = raw.firstIndex(of: "#") else { return raw }
        return String(raw[..<idx])
    }
}
