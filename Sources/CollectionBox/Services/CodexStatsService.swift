import Foundation
import SQLite3

enum StatsTimeRange: Int, CaseIterable, Identifiable {
    case last5Hours = 0, today = 1, last7Days = 2, last30Days = 3
    var id: Int { rawValue }
    var title: String { ["5小时", "今天", "7天", "30天"][rawValue] }

}

struct TrendPoint: Identifiable {
    let id = UUID()
    let label: String
    let tokens: Int
}

struct CodexStats {
    let currentTokens: Int
    let previousTokens: Int
    let currentSessions: Int
    let previousSessions: Int

    var tokenTrend: Double? {
        guard previousTokens > 0 else { return nil }
        return Double(currentTokens - previousTokens) / Double(previousTokens) * 100
    }

    var sessionTrend: Double? {
        guard previousSessions > 0 else { return nil }
        return Double(currentSessions - previousSessions) / Double(previousSessions) * 100
    }

    var formattedTokens: String {
        if currentTokens >= 1_000_000_000 {
            return String(format: "%.1fB", Double(currentTokens) / 1_000_000_000)
        } else if currentTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(currentTokens) / 1_000_000)
        } else if currentTokens >= 1000 {
            return String(format: "%.1fK", Double(currentTokens) / 1000)
        }
        return "\(currentTokens)"
    }

    var formattedSessions: String { "\(currentSessions)" }
}

final class CodexStatsService {
    private let dbPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Probe known paths; use whichever has the newest mtime
        let candidates = [
            ".codex/state_5.sqlite",           // Current (Jun 2026)
            ".codex/sqlite/state_5.sqlite",    // Previous
        ]
        var bestPath = home.appendingPathComponent(candidates[0]).path
        var bestMtime = Date.distantPast
        for rel in candidates {
            let url = home.appendingPathComponent(rel)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mt = attrs[.modificationDate] as? Date, mt > bestMtime {
                bestMtime = mt
                bestPath = url.path
            }
        }
        dbPath = bestPath
    }

    func fetchStats(for range: StatsTimeRange) -> CodexStats {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let cal = Calendar.current

        var currentStart: Int
        var currentEnd = nowUnix
        var previousStart: Int
        var previousEnd: Int

        switch range {
        case .last5Hours:
            let fiveHours: TimeInterval = 5 * 3600
            currentEnd = nowUnix
            currentStart = nowUnix - Int(fiveHours)
            previousEnd = currentStart
            previousStart = currentStart - Int(fiveHours)
        case .today:
            let todayStart = cal.startOfDay(for: now)
            currentStart = Int(todayStart.timeIntervalSince1970)
            currentEnd = nowUnix
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            previousStart = Int(yesterdayStart.timeIntervalSince1970)
            previousEnd = currentStart
        case .last7Days:
            let sevenDays: TimeInterval = 7 * 86400
            currentStart = nowUnix - Int(sevenDays)
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - Int(sevenDays)
        case .last30Days:
            let thirtyDays: TimeInterval = 30 * 86400
            currentStart = nowUnix - Int(thirtyDays)
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - Int(thirtyDays)
        }

        let current = queryRange(start: currentStart, end: currentEnd)
        let previous = queryRange(start: previousStart, end: previousEnd)

        return CodexStats(
            currentTokens: current.tokens,
            previousTokens: previous.tokens,
            currentSessions: current.sessions,
            previousSessions: previous.sessions
        )
    }

    /// Per-thread usage records for the dashboard (same source as the panel:
    /// one row per thread, `tokens_used` is the thread lifetime total).
    func collectRecords(sinceUnix: Int) -> [(tsMs: Int64, tokens: Int, sessionId: String, model: String?)] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, model, updated_at, tokens_used FROM threads WHERE updated_at >= ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(sinceUnix))

        var records: [(tsMs: Int64, tokens: Int, sessionId: String, model: String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let updatedAt = sqlite3_column_int64(stmt, 2)
            let tokens = Int(sqlite3_column_int64(stmt, 3))
            records.append((tsMs: updatedAt * 1000, tokens: tokens, sessionId: id, model: (model?.isEmpty == false) ? model : nil))
        }
        return records
    }

    func fetchTrend(for range: StatsTimeRange) -> [TrendPoint] {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let cal = Calendar.current
        let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT())

        var startUnix: Int
        var bucketSeconds: Int
        var strftimeFmt: String
        var labelFmt: String

        switch range {
        case .last5Hours:
            startUnix = nowUnix - 5 * 3600
            bucketSeconds = 1500
            strftimeFmt = "%H:%M"
            labelFmt = "%H:%M"
        case .today:
            startUnix = Int(cal.startOfDay(for: now).timeIntervalSince1970)
            bucketSeconds = 3600
            strftimeFmt = "%H"
            labelFmt = ":00"
        case .last7Days:
            startUnix = nowUnix - 7 * 86400
            bucketSeconds = 86400
            strftimeFmt = "%Y-%m-%d"
            labelFmt = "M/d"
        case .last30Days:
            startUnix = nowUnix - 30 * 86400
            bucketSeconds = 86400
            strftimeFmt = "%Y-%m-%d"
            labelFmt = "M/d"
        }

        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        // Single GROUP BY query using SQLite strftime with local timezone offset
        let tzSeconds = Int(tzOffset)
        let sql = "SELECT (updated_at + \(tzSeconds)) / \(bucketSeconds) as bucket, SUM(tokens_used) FROM threads WHERE updated_at >= ? AND updated_at < ? GROUP BY bucket ORDER BY bucket"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(startUnix))
        sqlite3_bind_int(stmt, 2, Int32(nowUnix))

        // Collect results
        var bucketMap: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucket = Int(sqlite3_column_int(stmt, 0))
            let tokens = Int(sqlite3_column_int64(stmt, 1))
            bucketMap[bucket] = tokens
        }

        // Generate all expected buckets and fill in data
        var points: [TrendPoint] = []
        var bucketStart = (startUnix + Int(tzOffset)) / bucketSeconds
        let currentBucket = (nowUnix + Int(tzOffset)) / bucketSeconds

        while bucketStart <= currentBucket {
            let tokens = bucketMap[bucketStart] ?? 0
            let dateTs = TimeInterval(bucketStart * bucketSeconds) - tzOffset
            let bucketDate = Date(timeIntervalSince1970: dateTs)

            let label: String
            if range == .today {
                let h = Calendar.current.component(.hour, from: bucketDate)
                label = String(format: "%d:00", h)
            } else if range == .last5Hours {
                let fmt = DateFormatter()
                fmt.dateFormat = "HH:mm"
                label = fmt.string(from: bucketDate)
            } else {
                let fmt = DateFormatter()
                fmt.dateFormat = "M/d"
                label = fmt.string(from: bucketDate)
            }

            points.append(TrendPoint(label: label, tokens: tokens))
            bucketStart += 1
        }
        return points
    }

    /// Open the database with retry — WAL checkpoints by Codex Desktop can briefly lock the file.
    private func openDB(retries: Int = 3) -> OpaquePointer? {
        for _ in 0..<retries {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
            if rc == SQLITE_OK, let db = db {
                sqlite3_busy_timeout(db, 5000)
                return db
            }
            if let db = db { sqlite3_close(db) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func queryRange(start: Int, end: Int) -> (tokens: Int, sessions: Int) {
        guard let db = openDB() else { return (0, 0) }
        defer { sqlite3_close(db) }

        let sql = "SELECT COALESCE(SUM(tokens_used), 0), COUNT(*) FROM threads WHERE updated_at >= ? AND updated_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(start))
        sqlite3_bind_int(stmt, 2, Int32(end))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let tokens = Int(sqlite3_column_int64(stmt, 0))
            let sessions = Int(sqlite3_column_int(stmt, 1))
            return (tokens, sessions)
        }

        return (0, 0)
    }
}
