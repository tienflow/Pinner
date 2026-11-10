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

/// Token usage statistics for Codex Desktop, scanned from rollout JSONL logs
/// with database fallback.
///
/// Codex Desktop's `threads` table in SQLite (`state_5.sqlite`) only records the
/// latest model chosen for a thread and the total cumulative tokens across its
/// lifetime. When a user switches models mid-thread, attributing all tokens to
/// the session-level model severely distorts stats (e.g. earlier DeepSeek turns
/// being attributed to a later LongCat switch).
///
/// This service parses the underlying rollout JSONL files pointed to by
/// `threads.rollout_path` to attribute each turn's tokens, fresh input, cached
/// tokens and output to the exact model and timestamp of that turn. If a rollout
/// file is absent or cannot be parsed, it falls back to the thread-level totals.
final class CodexStatsService: Sendable {
    private let dbPath: String

    struct UsageRecord: Codable, Sendable {
        let tsMs: Int64
        let sessionId: String
        let tokens: Int
        let freshInput: Int
        let cached: Int
        let output: Int
        let model: String?
        let title: String?
    }

    struct DiskFileCacheEntry: Codable, Sendable {
        let mtime: TimeInterval
        let size: Int64
        let records: [UsageRecord]
    }

    private struct ScanCache {
        let sinceUnix: Int
        let records: [UsageRecord]
        let at: Date
    }

    private static let cacheLock = NSLock()
    private static var scanCache: ScanCache?
    private static var persistentCache: [String: DiskFileCacheEntry]?
    private static let scanGate = ScanGate()

    static let scannerVersion = 1

    static let cacheFileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let dir = base.appendingPathComponent("com.tienyeung.Pinner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex_scan_cache.v\(scannerVersion).json")
    }()

    private static func getDiskCache() -> [String: DiskFileCacheEntry] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = persistentCache { return existing }
        let loaded = loadDiskCache()
        persistentCache = loaded
        return loaded
    }

    private static func loadDiskCache() -> [String: DiskFileCacheEntry] {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let dict = try? JSONDecoder().decode([String: DiskFileCacheEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func updateDiskCache(_ newEntries: [String: DiskFileCacheEntry]) {
        guard !newEntries.isEmpty else { return }
        cacheLock.lock()
        var current = persistentCache ?? loadDiskCache()
        for (k, v) in newEntries {
            current[k] = v
        }
        persistentCache = current
        cacheLock.unlock()
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            ".codex/state_5.sqlite",
            ".codex/sqlite/state_5.sqlite",
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

    private func cachedCollect(sinceUnix: Int, force: Bool = false) -> [UsageRecord] {
        Self.cacheLock.lock()
        if force { Self.scanCache = nil }
        let cached = Self.scanCache
        Self.cacheLock.unlock()

        if !force, let cached = cached, cached.sinceUnix <= sinceUnix,
           Date().timeIntervalSince(cached.at) < 120 {
            return cached.records.filter { $0.tsMs >= Int64(sinceUnix) * 1000 }
        }

        let records = Self.scanGate.run(key: "\(sinceUnix)") {
            collect(sinceUnix: sinceUnix)
        }

        Self.cacheLock.lock()
        Self.scanCache = ScanCache(sinceUnix: sinceUnix, records: records, at: Date())
        Self.cacheLock.unlock()

        return records
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
            let fiveHours = 5 * 3600
            currentEnd = nowUnix
            currentStart = nowUnix - fiveHours
            previousEnd = currentStart
            previousStart = currentStart - fiveHours
        case .today:
            let todayStart = cal.startOfDay(for: now)
            currentStart = Int(todayStart.timeIntervalSince1970)
            currentEnd = nowUnix
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            previousStart = Int(yesterdayStart.timeIntervalSince1970)
            previousEnd = currentStart
        case .last7Days:
            let sevenDays = 7 * 86400
            currentStart = nowUnix - sevenDays
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - sevenDays
        case .last30Days:
            let thirtyDays = 30 * 86400
            currentStart = nowUnix - thirtyDays
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - thirtyDays
        }

        let records = cachedCollect(sinceUnix: previousStart)

        var curTokens = 0, prevTokens = 0
        var curSessions = Set<String>(), prevSessions = Set<String>()

        let currentStartMs = Int64(currentStart) * 1000
        let currentEndMs = Int64(currentEnd) * 1000
        let previousStartMs = Int64(previousStart) * 1000
        let previousEndMs = Int64(previousEnd) * 1000

        for r in records {
            if r.tsMs >= currentStartMs && r.tsMs < currentEndMs {
                curTokens += r.tokens
                curSessions.insert(r.sessionId)
            } else if r.tsMs >= previousStartMs && r.tsMs < previousEndMs {
                prevTokens += r.tokens
                prevSessions.insert(r.sessionId)
            }
        }

        return CodexStats(
            currentTokens: curTokens,
            previousTokens: prevTokens,
            currentSessions: curSessions.count,
            previousSessions: prevSessions.count
        )
    }

    /// Turn-level usage records for the dashboard.
    func collectRecords(
        sinceUnix: Int,
        force: Bool = false
    ) -> [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?)] {
        let records = cachedCollect(sinceUnix: sinceUnix, force: force)
        return records.map {
            ($0.tsMs, $0.tokens, $0.freshInput, $0.cached, $0.output, $0.sessionId, $0.model, $0.title)
        }
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

        let records = cachedCollect(sinceUnix: startUnix)

        var bucketMap: [Int: Int] = [:]
        for r in records {
            let tsSec = Double(r.tsMs) / 1000.0
            if tsSec >= Double(startUnix) && tsSec < Double(nowUnix) {
                let bucket = Int((tsSec + tzOffset) / Double(bucketSeconds))
                bucketMap[bucket, default: 0] += r.tokens
            }
        }

        var points: [TrendPoint] = []
        var bucketStart = Int((Double(startUnix) + tzOffset) / Double(bucketSeconds))
        let currentBucket = Int((Double(nowUnix) + tzOffset) / Double(bucketSeconds))

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

    private struct ThreadCandidate {
        let id: String
        let model: String?
        let title: String?
        let rolloutPath: String?
        let updatedAt: Int64
        let tokensUsed: Int
    }

    private func collect(sinceUnix: Int) -> [UsageRecord] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, model, title, rollout_path, updated_at, tokens_used FROM threads WHERE updated_at >= ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(sinceUnix))

        var candidates: [ThreadCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let rolloutPath = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let updatedAt = sqlite3_column_int64(stmt, 4)
            let tokensUsed = Int(sqlite3_column_int64(stmt, 5))

            candidates.append(ThreadCandidate(
                id: id,
                model: (model?.isEmpty == false) ? model : nil,
                title: (title?.isEmpty == false) ? title : nil,
                rolloutPath: (rolloutPath?.isEmpty == false) ? rolloutPath : nil,
                updatedAt: updatedAt,
                tokensUsed: tokensUsed
            ))
        }

        guard !candidates.isEmpty else { return [] }

        let diskCache = Self.getDiskCache()
        var perCandidate = [[UsageRecord]](repeating: [], count: candidates.count)
        let newEntriesLock = NSLock()
        var newEntries: [String: DiskFileCacheEntry] = [:]
        let sinceMs = Int64(sinceUnix) * 1000

        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let c = candidates[i]
            guard let rpath = c.rolloutPath, !rpath.isEmpty,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: rpath),
                  let mdate = attrs[.modificationDate] as? Date,
                  let fsize = attrs[.size] as? NSNumber else {
                // Fallback to thread-level row if rollout file is absent
                perCandidate[i] = [UsageRecord(
                    tsMs: c.updatedAt * 1000,
                    sessionId: c.id,
                    tokens: c.tokensUsed,
                    freshInput: 0,
                    cached: 0,
                    output: 0,
                    model: c.model,
                    title: c.title
                )]
                return
            }

            let mtime = mdate.timeIntervalSince1970
            let size = fsize.int64Value

            if let entry = diskCache[rpath], entry.mtime == mtime && entry.size == size {
                perCandidate[i] = entry.records.filter { $0.tsMs >= sinceMs }
            } else {
                let allRecs = Self.processRolloutFile(
                    at: rpath,
                    sessionId: c.id,
                    fallbackModel: c.model,
                    fallbackTitle: c.title,
                    fallbackUpdatedMs: c.updatedAt * 1000,
                    fallbackTokensUsed: c.tokensUsed
                )
                let entry = DiskFileCacheEntry(mtime: mtime, size: size, records: allRecs)
                newEntriesLock.lock()
                newEntries[rpath] = entry
                newEntriesLock.unlock()
                perCandidate[i] = allRecs.filter { $0.tsMs >= sinceMs }
            }
        }

        if !newEntries.isEmpty {
            Self.updateDiskCache(newEntries)
        }

        var allRecords: [UsageRecord] = []
        for list in perCandidate {
            allRecords.append(contentsOf: list)
        }
        return allRecords
    }

    private static let tokenUsageTag = Data("\"token_usage_record\"".utf8)
    private static let turnContextTag = Data("\"turn_context\"".utf8)
    private static let threadSettingsTag = Data("\"thread_settings\"".utf8)

    private static func processRolloutFile(
        at path: String,
        sessionId: String,
        fallbackModel: String?,
        fallbackTitle: String?,
        fallbackUpdatedMs: Int64,
        fallbackTokensUsed: Int
    ) -> [UsageRecord] {
        let url = URL(fileURLWithPath: path)
        var records: [UsageRecord] = []
        var currentModel: String? = fallbackModel

        JSONLReader.forEachLine(of: url, requiredTags: [tokenUsageTag, turnContextTag, threadSettingsTag]) { line in
            if line.firstRange(of: tokenUsageTag) != nil {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let payload = d["payload"] as? [String: Any],
                      let usage = payload["usage"] as? [String: Any] else { return }

                let inp = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
                let cached = (usage["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
                let out = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
                let tot = (usage["total_tokens"] as? NSNumber)?.intValue ?? (inp + out)
                let fresh = max(0, inp - cached)

                var tsMs: Int64 = fallbackUpdatedMs
                if let tsStr = d["timestamp"] as? String,
                   let parsed = ISO8601DateHelper.parseMs(tsStr) {
                    tsMs = parsed
                }

                records.append(UsageRecord(
                    tsMs: tsMs,
                    sessionId: sessionId,
                    tokens: tot,
                    freshInput: fresh,
                    cached: cached,
                    output: out,
                    model: currentModel,
                    title: fallbackTitle
                ))
            } else if line.firstRange(of: turnContextTag) != nil {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let payload = d["payload"] as? [String: Any] else { return }

                if let m = payload["model"] as? String, !m.isEmpty {
                    currentModel = m
                } else if let mode = payload["collaboration_mode"] as? [String: Any],
                          let settings = mode["settings"] as? [String: Any],
                          let m = settings["model"] as? String, !m.isEmpty {
                    currentModel = m
                }
            } else if line.firstRange(of: threadSettingsTag) != nil {
                guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let payload = d["payload"] as? [String: Any],
                      let settings = payload["thread_settings"] as? [String: Any],
                      let m = settings["model"] as? String, !m.isEmpty else { return }
                currentModel = m
            }
        }

        if records.isEmpty && fallbackTokensUsed > 0 {
            records.append(UsageRecord(
                tsMs: fallbackUpdatedMs,
                sessionId: sessionId,
                tokens: fallbackTokensUsed,
                freshInput: 0,
                cached: 0,
                output: 0,
                model: fallbackModel,
                title: fallbackTitle
            ))
        }

        return records
    }
}

private enum ISO8601DateHelper {
    private static let lock = NSLock()
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseMs(_ str: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        if let d = withFractional.date(from: str) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        if let d = standard.date(from: str) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
