import Foundation
import SQLite3

struct WorkBuddyStats {
    let currentTokens: Int
    let previousTokens: Int
    let currentSessions: Int
    let previousSessions: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    /// WorkBuddy's input_tokens already includes cached reads, so the fresh
    /// part is the remainder.
    var freshInputTokens: Int {
        max(0, inputTokens - cacheReadTokens)
    }

    var tokenTrend: Double? {
        guard previousTokens > 0 else { return nil }
        return Double(currentTokens - previousTokens) / Double(previousTokens) * 100
    }

    var sessionTrend: Double? {
        guard previousSessions > 0 else { return nil }
        return Double(currentSessions - previousSessions) / Double(previousSessions) * 100
    }

    var cacheHitRate: Double {
        guard inputTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(inputTokens) * 100
    }

    var formattedTokens: String { Self.formatTokens(currentTokens) }
    var formattedInput: String { Self.formatTokens(freshInputTokens) }
    var formattedOutput: String { Self.formatTokens(outputTokens) }
    var formattedCache: String { Self.formatTokens(cacheReadTokens) }
    var formattedSessions: String { "\(currentSessions)" }

    static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.2fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1000 {
            return String(format: "%.1fK", Double(tokens) / 1000)
        }
        return "\(tokens)"
    }
}

/// Token usage statistics for WorkBuddy, scanned from local session files.
///
/// Authoritative source per the workbuddy-usage-stats skill:
/// `~/.workbuddy/projects/**/*.jsonl` (including `subagents/`), where each
/// assistant message carries
/// `message.usage = {input_tokens, output_tokens, total_tokens, cache_read_input_tokens}`.
/// `input_tokens` already contains `cache_read_input_tokens`; timestamps are
/// UTC milliseconds; records are de-duplicated by message id.
final class WorkBuddyStatsService: Sendable {
    private let projectsDir: URL

    init() {
        projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects")
    }

    private struct UsageRecord {
        let tsMs: Int64
        let sessionId: String
        let input: Int
        let output: Int
        let cacheRead: Int
    }

    // A full scan walks hundreds of MB of session files; cache the newest
    // scan briefly so fetchStats + fetchTrend (and re-refreshes) share it.
    private struct ScanCache {
        let sinceMs: Int64
        let records: [UsageRecord]
        let at: Date
    }

    private static let cacheLock = NSLock()
    private static var scanCache: ScanCache?

    private func cachedCollect(sinceMs: Int64) -> [UsageRecord] {
        Self.cacheLock.lock()
        let cached = Self.scanCache
        Self.cacheLock.unlock()
        if let cached = cached, cached.sinceMs <= sinceMs,
           Date().timeIntervalSince(cached.at) < 120 {
            return cached.records.filter { $0.tsMs >= sinceMs }
        }
        let records = collect(sinceMs: sinceMs)
        Self.cacheLock.lock()
        Self.scanCache = ScanCache(sinceMs: sinceMs, records: records, at: Date())
        Self.cacheLock.unlock()
        return records
    }

    func fetchStats(for range: StatsTimeRange) -> WorkBuddyStats {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let cal = Calendar.current

        var currentStartMs: Int64
        var previousStartMs: Int64
        let currentEndMs = nowMs
        let previousEndMs: Int64

        switch range {
        case .last5Hours:
            let span: Int64 = 5 * 3600 * 1000
            currentStartMs = nowMs - span
            previousStartMs = currentStartMs - span
            previousEndMs = currentStartMs
        case .today:
            let todayStart = Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
            currentStartMs = todayStart
            previousStartMs = todayStart - 24 * 3600 * 1000
            previousEndMs = currentStartMs
        case .last7Days:
            let span: Int64 = 7 * 86400 * 1000
            currentStartMs = nowMs - span
            previousStartMs = currentStartMs - span
            previousEndMs = currentStartMs
        case .last30Days:
            let span: Int64 = 30 * 86400 * 1000
            currentStartMs = nowMs - span
            previousStartMs = currentStartMs - span
            previousEndMs = currentStartMs
        }

        let records = cachedCollect(sinceMs: previousStartMs)

        var curTokens = 0, prevTokens = 0
        var curInput = 0, curOutput = 0, curCache = 0
        var curSessions = Set<String>(), prevSessions = Set<String>()

        for r in records {
            if r.tsMs >= currentStartMs && r.tsMs < currentEndMs {
                curTokens += r.input + r.output
                curInput += r.input
                curOutput += r.output
                curCache += r.cacheRead
                curSessions.insert(r.sessionId)
            } else if r.tsMs >= previousStartMs && r.tsMs < previousEndMs {
                prevTokens += r.input + r.output
                prevSessions.insert(r.sessionId)
            }
        }

        return WorkBuddyStats(
            currentTokens: curTokens,
            previousTokens: prevTokens,
            currentSessions: curSessions.count,
            previousSessions: prevSessions.count,
            inputTokens: curInput,
            outputTokens: curOutput,
            cacheReadTokens: curCache
        )
    }

    func fetchTrend(for range: StatsTimeRange) -> [TrendPoint] {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let cal = Calendar.current
        let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT())

        var startUnix: Int
        var bucketSeconds: Int

        switch range {
        case .last5Hours:
            startUnix = nowUnix - 5 * 3600
            bucketSeconds = 1500
        case .today:
            startUnix = Int(cal.startOfDay(for: now).timeIntervalSince1970)
            bucketSeconds = 3600
        case .last7Days:
            startUnix = nowUnix - 7 * 86400
            bucketSeconds = 86400
        case .last30Days:
            startUnix = nowUnix - 30 * 86400
            bucketSeconds = 86400
        }

        let records = cachedCollect(sinceMs: Int64(startUnix) * 1000)
        var bucketMap: [Int: Int] = [:]
        for r in records {
            let ts = Int(r.tsMs / 1000)
            if ts >= startUnix && ts < nowUnix {
                let bucket = Int((Double(ts) + tzOffset) / Double(bucketSeconds))
                bucketMap[bucket, default: 0] += r.input + r.output
            }
        }

        var points: [TrendPoint] = []
        var bucketStart = Int((Double(startUnix) + tzOffset) / Double(bucketSeconds))
        let currentBucket = Int((Double(nowUnix) + tzOffset) / Double(bucketSeconds))

        while bucketStart <= currentBucket {
            let tokens = bucketMap[bucketStart] ?? 0
            let bucketDate = Date(timeIntervalSince1970: TimeInterval(bucketStart * bucketSeconds) - tzOffset)

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

    /// Per-turn usage records for the dashboard, with the turn's session
    /// model and title resolved from the sessions table.
    /// `freshInput` = input − cache_read (input includes cached reads here).
    func collectRecords(sinceMs: Int64) -> [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?)] {
        let records = cachedCollect(sinceMs: sinceMs)
        let info = sessionInfoMap()
        return records.map { r in
            let cached = r.cacheRead
            return (tsMs: r.tsMs, tokens: r.input + r.output,
                    freshInput: max(0, r.input - cached), cached: cached, output: r.output,
                    sessionId: r.sessionId, model: info[r.sessionId]?.model, title: info[r.sessionId]?.title)
        }
    }

    private struct SessionInfo {
        let model: String?
        let title: String?
    }

    /// session_id -> (model, title) from ~/.workbuddy/workbuddy.db; empty map
    /// when the DB is locked or missing (records then fall into unknown).
    private func sessionInfoMap() -> [String: SessionInfo] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var db: OpaquePointer?
        for _ in 0..<3 {
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK { break }
            if db != nil { sqlite3_close(db); db = nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let db = db else { return [:] }
        sqlite3_busy_timeout(db, 3000)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, model, title FROM sessions", -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var map: [String: SessionInfo] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            map[id] = SessionInfo(
                model: (model?.isEmpty == false) ? model : nil,
                title: (title?.isEmpty == false) ? title : nil
            )
        }
        return map
    }

    // MARK: - Session File Scanning

    /// Scan all session jsonl files (recursively, including subagents) whose
    /// modification time falls within the window, extracting per-turn usage.
    private func collect(sinceMs: Int64) -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }
        let minDate = Date(timeIntervalSince1970: TimeInterval(sinceMs) / 1000)

        let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var records: [UsageRecord] = []
        var seenMessageIDs = Set<String>()

        while let element = enumerator?.nextObject() as? URL {
            guard element.pathExtension == "jsonl" else { continue }
            if let values = try? element.resourceValues(forKeys: [.contentModificationDateKey]),
               let mdate = values.contentModificationDate, mdate < minDate {
                continue
            }

            guard let content = try? String(contentsOf: element, encoding: .utf8) else { continue }
            let project = element.deletingLastPathComponent().lastPathComponent

            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"usage\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = d["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                guard let tsNumber = d["timestamp"] as? NSNumber else { continue }
                let tsMs = tsNumber.int64Value
                if tsMs < sinceMs { continue }

                // Same message id can appear in multiple files — keep first only.
                if let mid = d["id"] as? String {
                    guard !seenMessageIDs.contains(mid) else { continue }
                    seenMessageIDs.insert(mid)
                }

                let sessionId = (d["sessionId"] as? String) ?? project
                records.append(UsageRecord(
                    tsMs: tsMs,
                    sessionId: sessionId,
                    input: (usage["input_tokens"] as? NSNumber)?.intValue ?? 0,
                    output: (usage["output_tokens"] as? NSNumber)?.intValue ?? 0,
                    cacheRead: (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                ))
            }
        }

        return records
    }
}
