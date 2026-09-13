import Foundation
import SQLite3

struct GeminiStats {
    let currentTokens: Int
    let previousTokens: Int
    let currentSessions: Int
    let previousSessions: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int

    var tokenTrend: Double? {
        guard previousTokens > 0 else { return nil }
        return Double(currentTokens - previousTokens) / Double(previousTokens) * 100
    }

    var sessionTrend: Double? {
        guard previousSessions > 0 else { return nil }
        return Double(currentSessions - previousSessions) / Double(previousSessions) * 100
    }

    var cacheHitRate: Double {
        let totalPrompt = inputTokens + cacheReadTokens
        guard totalPrompt > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(totalPrompt) * 100
    }

    var formattedTokens: String {
        Self.formatTokens(currentTokens)
    }

    var formattedInput: String {
        Self.formatTokens(inputTokens)
    }

    var formattedOutput: String {
        Self.formatTokens(outputTokens)
    }

    var formattedCache: String {
        Self.formatTokens(cacheReadTokens)
    }

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

final class GeminiStatsService {
    private let conversationsDir: URL
    private let summaryDbPath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".gemini/antigravity")
        conversationsDir = baseDir.appendingPathComponent("conversations")
        summaryDbPath = baseDir.appendingPathComponent("conversation_summaries.db").path
    }

    func fetchStats(for range: StatsTimeRange) -> GeminiStats {
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

        let eligibleFiles = getEligibleDbFiles(since: previousStart)

        var curTokens = 0
        var prevTokens = 0
        var curInput = 0
        var curOutput = 0
        var curCache = 0
        var curSessions = Set<String>()
        var prevSessions = Set<String>()

        for (cid, fileUrl) in eligibleFiles {
            let steps = querySteps(from: fileUrl.path)
            for step in steps {
                let ts = step.timestamp
                if ts >= currentStart && ts < currentEnd {
                    curTokens += step.totalTokens
                    curInput += step.inputTokens
                    curOutput += step.outputTokens
                    curCache += step.cacheReadTokens
                    curSessions.insert(cid)
                } else if ts >= previousStart && ts < previousEnd {
                    prevTokens += step.totalTokens
                    prevSessions.insert(cid)
                }
            }
        }

        return GeminiStats(
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

        let eligibleFiles = getEligibleDbFiles(since: startUnix)
        var bucketMap: [Int: Int] = [:]

        for (_, fileUrl) in eligibleFiles {
            let steps = querySteps(from: fileUrl.path)
            for step in steps {
                let ts = step.timestamp
                if ts >= startUnix && ts < nowUnix {
                    let bucket = Int((Double(ts) + tzOffset) / Double(bucketSeconds))
                    bucketMap[bucket, default: 0] += step.totalTokens
                }
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

    /// Per-step usage records for the dashboard. Antigravity payloads carry
    /// no model name, so callers bucket these under an "unknown" model.
    /// `freshInput`/`cached`/`output` give the input/output/cache split
    /// (input here excludes cached reads).
    func collectRecords(sinceUnix: Int) -> [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?)] {
        let titles = conversationTitleMap()
        var records: [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?)] = []
        for (cid, fileUrl) in getEligibleDbFiles(since: sinceUnix) {
            for step in queryStepsWithModels(from: fileUrl.path) where step.timestamp >= sinceUnix {
                records.append((
                    tsMs: Int64(step.timestamp) * 1000,
                    tokens: step.totalTokens,
                    freshInput: step.inputTokens,
                    cached: step.cacheReadTokens,
                    output: step.outputTokens,
                    sessionId: cid,
                    model: step.model,
                    title: titles[cid]
                ))
            }
        }
        return records
    }

    /// conversation_id -> title, read once per service lifetime. Falls back
    /// to an immutable read when the summary DB is WAL-locked.
    private func conversationTitleMap() -> [String: String] {
        if let cached = titleMapCache { return cached }
        var map: [String: String] = [:]
        queryReadOnly(path: summaryDbPath, sql: "SELECT conversation_id, title FROM conversation_summaries") { stmt in
            guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            if let title, !title.isEmpty { map[id] = title }
        }
        titleMapCache = map
        return map
    }
    private var titleMapCache: [String: String]?

    // MARK: - Internal DB & Protobuf Scanning

    private struct StepTokenUsage {
        let timestamp: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let model: String?

        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens
        }
    }

    /// Read-only query with an immutable fallback: Antigravity keeps its DBs
    /// in WAL mode, and a plain READONLY connection cannot create/access the
    /// -shm file while the app holds them (prepare fails with rc 14). The
    /// immutable URI skips the WAL and reads the main file — possibly missing
    /// the newest un-checkpointed rows, which is acceptable for statistics.
    private func queryReadOnly(path: String, sql: String, row: (OpaquePointer) -> Void) {
        for immutable in [false, true] {
            queryReadOnly(path: path, immutable: immutable, sql: sql, row: row)
        }
    }

    private func queryReadOnly(path: String, immutable: Bool, sql: String, row: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let target = immutable ? "file:\(path)?immutable=1" : path
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db = db else {
            if db != nil { sqlite3_close(db) }
            return
        }
        sqlite3_busy_timeout(db, 3000)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }

    /// Generation steps (step_type = 15) paired with their model name.
    /// `gen_metadata` rows line up by position with the step_type=15 rows
    /// (its idx is the Nth-generation sequence, steps.idx interleaves other
    /// step types).
    private func queryStepsWithModels(from dbPath: String) -> [StepTokenUsage] {
        // The two tables pair by position. On a live DB a step can land
        // between the two queries and leave the tail unpaired — those
        // records used to surface as phantom "未知" models. Retry the plain
        // read a few times (the writer settles quickly); on persistent
        // mismatch pair the aligned prefix — the unpaired tail is the
        // newest, still-being-written turn.
        for attempt in 0..<3 {
            var payloads: [Data] = []
            var models: [String?] = []
            readStepPayloads(dbPath: dbPath, into: &payloads)
            readGenModels(dbPath: dbPath, into: &models)
            if payloads.count == models.count {
                return pairSteps(payloads, with: models)
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
        var payloads: [Data] = []
        var models: [String?] = []
        readStepPayloads(dbPath: dbPath, into: &payloads)
        readGenModels(dbPath: dbPath, into: &models)
        let n = min(payloads.count, models.count)
        return pairSteps(Array(payloads.prefix(n)), with: Array(models.prefix(n)))
    }

    private func pairSteps(_ payloads: [Data], with models: [String?]) -> [StepTokenUsage] {
        var usages: [StepTokenUsage] = []
        for (i, payload) in payloads.enumerated() {
            guard let parsed = payload.withUnsafeBytes({ ptr -> StepTokenUsage? in
                guard let base = ptr.baseAddress else { return nil }
                return parseProtobufStep(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: ptr.count))
            }) else { continue }
            let model = i < models.count ? models[i] : nil
            usages.append(StepTokenUsage(
                timestamp: parsed.timestamp,
                inputTokens: parsed.inputTokens,
                outputTokens: parsed.outputTokens,
                cacheReadTokens: parsed.cacheReadTokens,
                model: model
            ))
        }
        return usages
    }

    private func readStepPayloads(dbPath: String, into payloads: inout [Data]) {
        queryReadOnly(path: dbPath,
                      sql: "SELECT step_payload FROM steps WHERE step_type = 15 ORDER BY idx") { stmt in
            if let blob = sqlite3_column_blob(stmt, 0) {
                payloads.append(Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0))))
            } else {
                payloads.append(Data())
            }
        }
    }

    private func readGenModels(dbPath: String, into models: inout [String?]) {
        queryReadOnly(path: dbPath,
                      sql: "SELECT data FROM gen_metadata ORDER BY idx") { stmt in
            if let blob = sqlite3_column_blob(stmt, 0) {
                let buffer = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_column_bytes(stmt, 0)))
                models.append(parseGenModel(buffer))
            } else {
                models.append(nil)
            }
        }
    }

    /// Model name from a gen_metadata blob. The name lives in a nested
    /// protobuf field 19 (a submessage alongside a model-api id), not at the
    /// top level, so walk wire-type-2 fields recursively (depth-capped) and
    /// validate the candidate looks like a model identifier.
    private func parseGenModel<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8, C.Index == Int {
        genModelWalk(bytes, depth: 0)
    }

    private func genModelWalk<C: Collection>(_ bytes: C, depth: Int) -> String? where C.Element == UInt8, C.Index == Int {
        guard depth < 4 else { return nil }
        var i = bytes.startIndex
        let n = bytes.endIndex
        while i < n {
            guard let (k, newI) = readVarint(bytes, from: i) else { break }
            i = newI
            let fnum = Int(k >> 3)
            let wtype = k & 7
            if wtype == 0 {
                guard let (_, nextI) = readVarint(bytes, from: i) else { break }
                i = nextI
            } else if wtype == 1 {
                i += 8
            } else if wtype == 5 {
                i += 4
            } else if wtype == 2 {
                guard let (len, nextI) = readVarint(bytes, from: i) else { break }
                i = nextI
                let length = Int(len)
                guard i + length <= n else { break }
                let slice = bytes[i..<(i + length)]
                if fnum == 19, let text = String(bytes: slice, encoding: .utf8),
                   length <= 64, looksLikeModelName(text) {
                    return text
                }
                if let nested = genModelWalk(slice, depth: depth + 1) {
                    return nested
                }
                i += length
            } else {
                break
            }
        }
        return nil
    }

    private func looksLikeModelName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { c in
            (c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "." || c == "_"))
        }
    }

    /// Retrieve conversation database files whose last modification date is on or after the timestamp.
    private func getEligibleDbFiles(since minUnix: Int) -> [(cid: String, url: URL)] {
        let minDate = Date(timeIntervalSince1970: TimeInterval(minUnix))
        guard let files = try? FileManager.default.contentsOfDirectory(at: conversationsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var results: [(cid: String, url: URL)] = []
        for file in files where file.pathExtension == "db" {
            let cid = file.deletingPathExtension().lastPathComponent
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let mdate = values.contentModificationDate {
                if mdate >= minDate {
                    results.append((cid, file))
                }
            } else {
                results.append((cid, file))
            }
        }
        return results
    }

    /// Open a database with retry and busy timeout to handle SQLite WAL locks.
    private func openDB(at path: String, retries: Int = 3) -> OpaquePointer? {
        for _ in 0..<retries {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
            if rc == SQLITE_OK, let db = db {
                sqlite3_busy_timeout(db, 5000)
                return db
            }
            if let db = db { sqlite3_close(db) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Query step_payload for model generation steps (step_type = 15) and parse token usage.
    private func querySteps(from dbPath: String) -> [StepTokenUsage] {
        queryStepsWithModels(from: dbPath)
    }

    /// Parse Step protobuf payload: extract CortexStepMetadata (tag 5) -> created_at (tag 1) and model_usage (tag 9).
    private func parseProtobufStep<C: Collection>(_ bytes: C) -> StepTokenUsage? where C.Element == UInt8, C.Index == Int {
        var i = bytes.startIndex
        let n = bytes.endIndex
        var metaRange: Range<Int>? = nil

        // Locate field 5 (CortexStepMetadata) in top Step message
        while i < n {
            guard let (k, newI) = readVarint(bytes, from: i) else { break }
            i = newI
            let fnum = k >> 3
            let wtype = k & 7
            if wtype == 0 {
                guard let (_, nextI) = readVarint(bytes, from: i) else { break }
                i = nextI
            } else if wtype == 2 {
                guard let (len, nextI) = readVarint(bytes, from: i) else { break }
                i = nextI
                let length = Int(len)
                guard i + length <= n else { break }
                if fnum == 5 {
                    metaRange = i..<(i + length)
                    break
                }
                i += length
            } else if wtype == 1 {
                i += 8
            } else if wtype == 5 {
                i += 4
            } else {
                break
            }
        }

        guard let mRange = metaRange else { return nil }

        // Parse CortexStepMetadata: field 1 (Timestamp), field 9 (ModelUsageStats)
        var mI = mRange.lowerBound
        let mEnd = mRange.upperBound
        var tsSec: Int? = nil
        var usageRange: Range<Int>? = nil

        while mI < mEnd {
            guard let (k, newI) = readVarint(bytes, from: mI) else { break }
            mI = newI
            let fnum = k >> 3
            let wtype = k & 7
            if wtype == 0 {
                guard let (_, nextI) = readVarint(bytes, from: mI) else { break }
                mI = nextI
            } else if wtype == 2 {
                guard let (len, nextI) = readVarint(bytes, from: mI) else { break }
                mI = nextI
                let length = Int(len)
                guard mI + length <= mEnd else { break }
                if fnum == 1 {
                    // Timestamp message: tag 1 is seconds (varint)
                    let tsSub = bytes[mI..<(mI + length)]
                    if let (tsK, tsI1) = readVarint(tsSub, from: mI), (tsK >> 3) == 1 {
                        if let (secVal, _) = readVarint(tsSub, from: tsI1) {
                            tsSec = Int(secVal)
                        }
                    }
                } else if fnum == 9 {
                    usageRange = mI..<(mI + length)
                }
                mI += length
            } else if wtype == 1 {
                mI += 8
            } else if wtype == 5 {
                mI += 4
            } else {
                break
            }
        }

        guard let ts = tsSec, let uRange = usageRange else { return nil }

        // Parse ModelUsageStats: field 2 (input_tokens), field 3 (output_tokens), field 5 (cache_read_tokens)
        var uI = uRange.lowerBound
        let uEnd = uRange.upperBound
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0

        while uI < uEnd {
            guard let (k, newI) = readVarint(bytes, from: uI) else { break }
            uI = newI
            let fnum = k >> 3
            let wtype = k & 7
            if wtype == 0 {
                guard let (val, nextI) = readVarint(bytes, from: uI) else { break }
                uI = nextI
                if fnum == 2 { inputTokens = Int(val) }
                else if fnum == 3 { outputTokens = Int(val) }
                else if fnum == 5 { cacheReadTokens = Int(val) }
            } else if wtype == 2 {
                guard let (len, nextI) = readVarint(bytes, from: uI) else { break }
                uI = nextI + Int(len)
            } else if wtype == 1 {
                uI += 8
            } else if wtype == 5 {
                uI += 4
            } else {
                break
            }
        }

        return StepTokenUsage(
            timestamp: ts,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            model: nil
        )
    }

    private func readVarint<C: Collection>(_ bytes: C, from index: C.Index) -> (val: UInt64, nextIndex: C.Index)? where C.Element == UInt8 {
        var cur = index
        var val: UInt64 = 0
        var shift: UInt64 = 0
        while cur < bytes.endIndex {
            let b = bytes[cur]
            cur = bytes.index(after: cur)
            val |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return (val, cur)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
