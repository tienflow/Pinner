import Foundation
import AppKit
import SQLite3

// MARK: - Cross-Module 7-Day Observation Digest (Privacy-Sanitized)

public struct WorkflowObservationDigest: Sendable, Codable {
    public struct DomainSummary: Sendable, Codable {
        public let domain: String
        public let visits: Int
        public let durationMinutes: Int
    }

    public struct BrowserDigest: Sendable, Codable {
        public let visits7d: Int
        public let durationMinutes7d: Int
        public let uniqueDomains7d: Int
        public let peakHour: Int?
        public let diaVisits7d: Int
        public let chromeVisits7d: Int
        public let topDomains: [DomainSummary]
    }

    public struct NamedCount: Sendable, Codable {
        public let name: String
        public let count: Int
        public let percentage: Double
    }

    public struct ClipboardDigest: Sendable, Codable {
        public let count7d: Int
        public let todayCount: Int
        public let avgDaily: Int
        public let peakHour: Int?
        public let typeBreakdown: [NamedCount]
        public let topApps: [NamedCount]
    }

    public struct InputAppSummary: Sendable, Codable {
        public let name: String
        public let keys: Int
        public let clicks: Int
    }

    public struct InputDigest: Sendable, Codable {
        public let totalKeys7d: Int
        public let totalClicks7d: Int
        public let mouseDistanceMeters7d: Double
        public let peakHour: Int?
        public let topApps: [InputAppSummary]
    }

    public struct TrafficDigest: Sendable, Codable {
        public let receivedBytes7d: UInt64
        public let sentBytes7d: UInt64
        public let totalBytes7d: UInt64
    }

    public struct KnowledgeCDigest: Sendable, Codable {
        public let totalAppMinutes7d: Int
        public let screenLitMinutes7d: Int
        public let topApps: [NamedCount]
        public let totalNotifications7d: Int
        public let topNotificationApps: [NamedCount]
    }

    public let browser: BrowserDigest?
    public let clipboard: ClipboardDigest?
    public let input: InputDigest?
    public let traffic: TrafficDigest?
    public let knowledgeC: KnowledgeCDigest?

    public var activeSourceLabels: [String] {
        var labels = ["Agent"]
        if browser != nil { labels.append("浏览") }
        if clipboard != nil { labels.append("剪贴") }
        if input != nil { labels.append("键鼠") }
        if traffic != nil { labels.append("流量") }
        if knowledgeC != nil { labels.append("系统") }
        return labels
    }

    public var hasCrossModuleData: Bool {
        browser != nil || clipboard != nil || input != nil || traffic != nil || knowledgeC != nil
    }

    public func formatForPrompt() -> String {
        var sections: [String] = []

        if let b = browser {
            let peak = b.peakHour.map { String(format: "%02d:00", $0) } ?? "无明显峰值"
            let domLines = b.topDomains.prefix(8).map {
                "  - \($0.domain): \($0.visits) 次 / \($0.durationMinutes) 分钟"
            }.joined(separator: "\n")
            sections.append("""
            【浏览器观测（近 7 天，已脱敏仅保留域名）】
            - 访问总量：\(b.visits7d) 次（Dia \(b.diaVisits7d) · Chrome \(b.chromeVisits7d)），有效停留约 \(formatMinutes(b.durationMinutes7d))，涉及 \(b.uniqueDomains7d) 个独立站点
            - 浏览活跃峰值时段：\(peak)
            - Top 访问域名：
            \(domLines.isEmpty ? "  - 暂无" : domLines)
            """)
        }

        if let c = clipboard {
            let peak = c.peakHour.map { String(format: "%02d:00", $0) } ?? "无明显峰值"
            let types = c.typeBreakdown.prefix(4).map {
                "\($0.name) \(Int($0.percentage * 100))%"
            }.joined(separator: " / ")
            let apps = c.topApps.prefix(5).map {
                "\($0.name)(\($0.count)次, \(Int($0.percentage * 100))%)"
            }.joined(separator: "、")
            sections.append("""
            【剪贴板观测（近 7 天，仅聚合计数不含原文）】
            - 复制吞吐：近 7 天 \(c.count7d) 次（今日 \(c.todayCount) 次，日均 \(c.avgDaily) 次），峰值时段 \(peak)
            - 形态分布：\(types.isEmpty ? "暂无" : types)
            - Top 来源应用：\(apps.isEmpty ? "暂无" : apps)
            """)
        }

        if let inp = input {
            let peak = inp.peakHour.map { String(format: "%02d:00", $0) } ?? "无明显峰值"
            let apps = inp.topApps.prefix(5).map {
                "\($0.name)(击键 \($0.keys), 点击 \($0.clicks))"
            }.joined(separator: "、")
            sections.append("""
            【键鼠输入观测（近 7 天）】
            - 总敲击：\(inp.totalKeys7d) 次，总点击：\(inp.totalClicks7d) 次，鼠标位移：\(String(format: "%.0f", inp.mouseDistanceMeters7d)) 米，输入高峰时段：\(peak)
            - Top 活跃应用：\(apps.isEmpty ? "暂无" : apps)
            """)
        }

        if let tr = traffic {
            sections.append("""
            【整机流量观测（近 7 天）】
            - 总流量：\(ByteCountFormatter.string(fromByteCount: Int64(tr.totalBytes7d), countStyle: .binary))（下行 \(ByteCountFormatter.string(fromByteCount: Int64(tr.receivedBytes7d), countStyle: .binary)) / 上行 \(ByteCountFormatter.string(fromByteCount: Int64(tr.sentBytes7d), countStyle: .binary))）
            """)
        }

        if let kc = knowledgeC {
            let apps = kc.topApps.prefix(5).map { "\($0.name) \(formatMinutes($0.count))" }.joined(separator: "、")
            let notifs = kc.topNotificationApps.prefix(4).map { "\($0.name)(\($0.count)条)" }.joined(separator: "、")
            sections.append("""
            【macOS 系统使用时间与通知打扰（KnowledgeC 近 7 天）】
            - 前台累计使用：\(formatMinutes(kc.totalAppMinutes7d))，屏幕点亮累计：\(formatMinutes(kc.screenLitMinutes7d))
            - Top 前台应用：\(apps.isEmpty ? "暂无" : apps)
            - 系统通知接收：共 \(kc.totalNotifications7d) 条，主要来源：\(notifs.isEmpty ? "暂无" : notifs)
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    private func formatMinutes(_ mins: Int) -> String {
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}

// MARK: - Collector

final class WorkflowDigestService: Sendable {
    static let shared = WorkflowDigestService()

    func collect7DayDigest() async -> WorkflowObservationDigest {
        // 1. Capture @MainActor state & in-memory stats
        let snapshotInput = await MainActor.run { () -> (
            browserEnabled: Bool,
            clipboardEnabled: Bool,
            inputDigest: WorkflowObservationDigest.InputDigest?,
            trafficDigest: WorkflowObservationDigest.TrafficDigest?,
            clipboardDBPath: String?
        ) in
            let modules = ModuleManager.shared
            let browserEnabled = modules.isEnabled(.browserStats)
            let clipboardEnabled = modules.isEnabled(.clipboardStats)

            let inputDigest: WorkflowObservationDigest.InputDigest? = {
                guard modules.isEnabled(.inputStats) else { return nil }
                let svc = InputStatsService.shared
                let series = svc.historySeries(days: 7)
                let totalKeys = series.reduce(0) { $0 + $1.keyCount }
                let totalClicks = series.reduce(0) { $0 + $1.clickCount }
                let totalDist = series.reduce(0.0) { $0 + $1.mouseDistanceMeters }
                guard totalKeys > 0 || totalClicks > 0 else { return nil }

                // Peak hour from today's hourly buckets (or nil if empty)
                let todayPeak = svc.stats.hourlyBuckets
                    .max(by: { ($0.keyCount + $0.clickCount) < ($1.keyCount + $1.clickCount) })
                let peakHour = (todayPeak.map { $0.keyCount + $0.clickCount } ?? 0) > 0 ? todayPeak?.hour : nil

                let topApps = svc.aggregatedAppStats(range: .days7).prefix(5).map {
                    WorkflowObservationDigest.InputAppSummary(
                        name: $0.appName,
                        keys: $0.keyCount,
                        clicks: $0.clickCount
                    )
                }
                return WorkflowObservationDigest.InputDigest(
                    totalKeys7d: totalKeys,
                    totalClicks7d: totalClicks,
                    mouseDistanceMeters7d: totalDist,
                    peakHour: peakHour,
                    topApps: topApps
                )
            }()

            let trafficDigest: WorkflowObservationDigest.TrafficDigest? = {
                guard modules.isEnabled(.traffic) else { return nil }
                let series = TrafficMonitorService.shared.historySeries(days: 7)
                let rx = series.reduce(UInt64(0)) { $0 + $1.received }
                let tx = series.reduce(UInt64(0)) { $0 + $1.sent }
                let total = rx + tx
                guard total > 0 else { return nil }
                return WorkflowObservationDigest.TrafficDigest(
                    receivedBytes7d: rx,
                    sentBytes7d: tx,
                    totalBytes7d: total
                )
            }()

            return (
                browserEnabled,
                clipboardEnabled,
                inputDigest,
                trafficDigest,
                ClipboardStatsService.locateDatabasePath()
            )
        }

        // 2. Run SQLite reads off the main actor
        return await Task.detached(priority: .userInitiated) {
            let browserDigest: WorkflowObservationDigest.BrowserDigest? = {
                guard snapshotInput.browserEnabled else { return nil }
                let profiles = BrowserStatsService.discoverProfiles()
                guard !profiles.isEmpty else { return nil }
                let data = BrowserStatsService.queryAllProfiles(profiles, range: .days7, source: .all)
                guard data.rangeVisits > 0 else { return nil }

                let peak = data.hourlyStats.max(by: { $0.visitCount < $1.visitCount })
                let peakHour = (peak?.visitCount ?? 0) > 0 ? peak?.hour : nil
                let topDomains = data.topDomains.map {
                    WorkflowObservationDigest.DomainSummary(
                        domain: $0.domain,
                        visits: $0.visitCount,
                        durationMinutes: Int($0.totalDurationSeconds / 60.0)
                    )
                }
                return WorkflowObservationDigest.BrowserDigest(
                    visits7d: data.rangeVisits,
                    durationMinutes7d: Int(data.rangeDurationSeconds / 60.0),
                    uniqueDomains7d: data.uniqueDomainsCount,
                    peakHour: peakHour,
                    diaVisits7d: data.diaVisits,
                    chromeVisits7d: data.chromeVisits,
                    topDomains: topDomains
                )
            }()

            let clipboardDigest: WorkflowObservationDigest.ClipboardDigest? = {
                guard snapshotInput.clipboardEnabled, let path = snapshotInput.clipboardDBPath else { return nil }
                guard let data = ClipboardStatsService.queryDatabase(at: path, range: .days7),
                      data.rangeCount > 0 else { return nil }

                let peak = data.hourlyStats.max(by: { $0.count < $1.count })
                let peakHour = (peak?.count ?? 0) > 0 ? peak?.hour : nil
                let types = data.typeStats.filter { $0.count > 0 }.map {
                    WorkflowObservationDigest.NamedCount(
                        name: $0.type.rawValue,
                        count: $0.count,
                        percentage: $0.percentage
                    )
                }
                let apps = data.topApps.prefix(5).map {
                    WorkflowObservationDigest.NamedCount(
                        name: Self.friendlyAppName(for: $0.bundleId),
                        count: $0.count,
                        percentage: $0.percentage
                    )
                }
                return WorkflowObservationDigest.ClipboardDigest(
                    count7d: data.rangeCount,
                    todayCount: data.todayCount,
                    avgDaily: data.avgDailyCount,
                    peakHour: peakHour,
                    typeBreakdown: types,
                    topApps: apps
                )
            }()

            let kcDigest = Self.probeKnowledgeC7DayDigest()

            return WorkflowObservationDigest(
                browser: browserDigest,
                clipboard: clipboardDigest,
                input: snapshotInput.inputDigest,
                traffic: snapshotInput.trafficDigest,
                knowledgeC: kcDigest
            )
        }.value
    }

    // MARK: - Optional Silent KnowledgeC Probe

    private static func openKnowledgeCDatabase(at kcPath: String) -> OpaquePointer? {
        for immutable in [false, true] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            let target = immutable ? "\(URL(fileURLWithPath: kcPath).absoluteString)?immutable=1" : kcPath
            guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            sqlite3_busy_timeout(db, 1500)
            var probe: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT 1 FROM ZOBJECT LIMIT 1", -1, &probe, nil) == SQLITE_OK {
                if let probe { sqlite3_finalize(probe) }
                return db
            }
            if let probe { sqlite3_finalize(probe) }
            sqlite3_close(db)
        }
        return nil
    }

    private static func probeKnowledgeC7DayDigest() -> WorkflowObservationDigest.KnowledgeCDigest? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let kcPath = (home as NSString).appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db")
        guard FileManager.default.isReadableFile(atPath: kcPath),
              let db = openKnowledgeCDatabase(at: kcPath) else { return nil }
        defer { sqlite3_close(db) }

        let nowRef = Date().timeIntervalSinceReferenceDate
        let d7Ref = nowRef - 7 * 86400
        let maxRef = nowRef + 3600

        // 1. App usage (/app/usage) — query full 7d groups so totals & shares aren't truncated by LIMIT
        var totalAppSeconds: Double = 0
        var topApps: [WorkflowObservationDigest.NamedCount] = []
        let appSql = """
        SELECT ZVALUESTRING, SUM(MAX(0, ZENDDATE - ZSTARTDATE)) AS dur
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
          AND ZSTARTDATE >= ?
          AND ZENDDATE <= ?
          AND ZVALUESTRING IS NOT NULL
        GROUP BY ZVALUESTRING
        ORDER BY dur DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, appSql, -1, &stmt, nil) == SQLITE_OK, let appStmt = stmt else {
            // If TCC blocks querying ZOBJECT, silently return nil
            return nil
        }
        sqlite3_bind_double(appStmt, 1, d7Ref)
        sqlite3_bind_double(appStmt, 2, maxRef)
        var rawApps: [(String, Double)] = []
        while sqlite3_step(appStmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(appStmt, 0) else { continue }
            let bundle = String(cString: ptr)
            let dur = sqlite3_column_double(appStmt, 1)
            totalAppSeconds += dur
            rawApps.append((bundle, dur))
        }
        sqlite3_finalize(appStmt)

        let totalAppDenom = max(1.0, totalAppSeconds)
        topApps = rawApps.prefix(5).map { bundle, dur in
            WorkflowObservationDigest.NamedCount(
                name: friendlyAppName(for: bundle),
                count: Int(dur / 60.0),
                percentage: dur / totalAppDenom
            )
        }

        // 2. Notification usage (/notification/usage)
        var totalNotifications = 0
        var topNotifs: [WorkflowObservationDigest.NamedCount] = []
        let notifSql = """
        SELECT m.Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID, COUNT(*) AS cnt
        FROM ZOBJECT o
        LEFT JOIN ZSTRUCTUREDMETADATA m ON o.ZSTRUCTUREDMETADATA = m.Z_PK
        WHERE o.ZSTREAMNAME = '/notification/usage'
          AND o.ZVALUESTRING = 'Receive'
          AND o.ZSTARTDATE >= ?
          AND o.ZENDDATE <= ?
        GROUP BY m.Z_DKNOTIFICATIONUSAGEMETADATAKEY__BUNDLEID
        ORDER BY cnt DESC
        """
        if sqlite3_prepare_v2(db, notifSql, -1, &stmt, nil) == SQLITE_OK, let notifStmt = stmt {
            sqlite3_bind_double(notifStmt, 1, d7Ref)
            sqlite3_bind_double(notifStmt, 2, maxRef)
            var rawNotifs: [(String, Int)] = []
            while sqlite3_step(notifStmt) == SQLITE_ROW {
                let bundle = sqlite3_column_text(notifStmt, 0).map { String(cString: $0) } ?? "unknown"
                let cnt = Int(sqlite3_column_int64(notifStmt, 1))
                totalNotifications += cnt
                rawNotifs.append((bundle, cnt))
            }
            sqlite3_finalize(notifStmt)
            let notifDenom = max(1, totalNotifications)
            topNotifs = rawNotifs.prefix(5).map { bundle, cnt in
                WorkflowObservationDigest.NamedCount(
                    name: friendlyAppName(for: bundle),
                    count: cnt,
                    percentage: Double(cnt) / Double(notifDenom)
                )
            }
        }

        // 3. Screen lit duration (/display/isBacklit)
        var screenLitSeconds: Double = 0
        let litSql = """
        SELECT COALESCE(SUM(MAX(0, ZENDDATE - ZSTARTDATE)), 0)
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/display/isBacklit'
          AND ZSTARTDATE >= ?
          AND ZENDDATE <= ?
        """
        if sqlite3_prepare_v2(db, litSql, -1, &stmt, nil) == SQLITE_OK, let litStmt = stmt {
            sqlite3_bind_double(litStmt, 1, d7Ref)
            sqlite3_bind_double(litStmt, 2, maxRef)
            if sqlite3_step(litStmt) == SQLITE_ROW {
                screenLitSeconds = sqlite3_column_double(litStmt, 0)
            }
            sqlite3_finalize(litStmt)
        }

        guard totalAppSeconds > 0 || totalNotifications > 0 || screenLitSeconds > 0 else {
            return nil
        }

        return WorkflowObservationDigest.KnowledgeCDigest(
            totalAppMinutes7d: Int(totalAppSeconds / 60.0),
            screenLitMinutes7d: Int(screenLitSeconds / 60.0),
            topApps: topApps,
            totalNotifications7d: totalNotifications,
            topNotificationApps: topNotifs
        )
    }

    private static func friendlyAppName(for bundleId: String) -> String {
        let lower = bundleId.lowercased()
        if lower.contains("antigravity") { return "Antigravity" }
        if lower.contains("zcode") { return "ZCode" }
        if lower.contains("dia") { return "Dia" }
        if lower.contains("chrome") { return "Chrome" }
        if lower.contains("wechat") || lower.contains("xinwechat") { return "微信" }
        if lower.contains("codex") { return "Codex" }
        if lower.contains("workbuddy") { return "WorkBuddy" }
        if lower.contains("ishot") { return "iShot" }
        if lower.contains("pinner") { return "Pinner" }
        if lower.contains("finder") { return "访达" }
        if lower.contains("mobilesms") { return "信息" }
        if lower.contains("ghostty") { return "Ghostty" }
        if lower.contains("xterminal") { return "XTerminal" }
        if lower.contains("obsidian") { return "Obsidian" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId.components(separatedBy: ".").last ?? bundleId
    }
}
