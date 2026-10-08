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

final class GeminiStatsService: Sendable {
    private let conversationsDir: URL
    private let summaryDbPath: String

    struct StepTokenUsage: Codable, Sendable {
        let timestamp: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let model: String?
        let durationMs: Int?

        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens
        }

        init(timestamp: Int, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, model: String?, durationMs: Int? = nil) {
            self.timestamp = timestamp
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.model = model
            self.durationMs = durationMs
        }

        enum CodingKeys: String, CodingKey {
            case timestamp, inputTokens, outputTokens, cacheReadTokens, model, durationMs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timestamp = try container.decode(Int.self, forKey: .timestamp)
            inputTokens = try container.decode(Int.self, forKey: .inputTokens)
            outputTokens = try container.decode(Int.self, forKey: .outputTokens)
            cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        }
    }

    struct DiskFileCacheEntry: Codable, Sendable {
        let mtime: TimeInterval
        let size: Int64
        let steps: [StepTokenUsage]
    }

    private struct DbFileMeta {
        let cid: String
        let url: URL
        let path: String
        let mtime: TimeInterval
        let size: Int64
    }

    private static let cacheLock = NSLock()
    private static var persistentCache: [String: DiskFileCacheEntry]?

    /// Parse-rule version. Part of the cache filename so a bump starts a fresh
    /// file: mtime/size alone cannot detect a change in how steps are parsed.
    static let scannerVersion = 2

    static let cacheFileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let dir = base.appendingPathComponent("com.tienyeung.Pinner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for legacy in ["gemini_scan_cache.json", "gemini_scan_cache_v2.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(legacy))
        }
        for stale in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = stale.lastPathComponent
            if name.hasPrefix("gemini_scan_cache.v"), name != "gemini_scan_cache.v\(scannerVersion).json" {
                try? FileManager.default.removeItem(at: stale)
            }
        }
        return dir.appendingPathComponent("gemini_scan_cache.v\(scannerVersion).json")
    }()

    static func resetMemoryCacheForTesting() {
        scanGate.reset()
        cacheLock.lock()
        persistentCache = nil
        cacheLock.unlock()
    }

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

    private let titleLock = NSLock()
    private var titleMapCache: [String: String]?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let baseDir = home.appendingPathComponent(".gemini/antigravity")
        conversationsDir = baseDir.appendingPathComponent("conversations")
        summaryDbPath = baseDir.appendingPathComponent("conversation_summaries.db").path
    }

    func fetchStatsAndTrend(for range: StatsTimeRange) -> (stats: GeminiStats, trend: [TrendPoint]) {
        let now = Date()
        let nowUnix = Int(now.timeIntervalSince1970)
        let cal = Calendar.current
        let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT())

        var currentStart: Int
        var currentEnd = nowUnix
        var previousStart: Int
        var previousEnd: Int
        var bucketSeconds: Int

        switch range {
        case .last5Hours:
            let fiveHours: TimeInterval = 5 * 3600
            currentEnd = nowUnix
            currentStart = nowUnix - Int(fiveHours)
            previousEnd = currentStart
            previousStart = currentStart - Int(fiveHours)
            bucketSeconds = 1500
        case .today:
            let todayStart = cal.startOfDay(for: now)
            currentStart = Int(todayStart.timeIntervalSince1970)
            currentEnd = nowUnix
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
            previousStart = Int(yesterdayStart.timeIntervalSince1970)
            previousEnd = currentStart
            bucketSeconds = 3600
        case .last7Days:
            let sevenDays: TimeInterval = 7 * 86400
            currentStart = nowUnix - Int(sevenDays)
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - Int(sevenDays)
            bucketSeconds = 86400
        case .last30Days:
            let thirtyDays: TimeInterval = 30 * 86400
            currentStart = nowUnix - Int(thirtyDays)
            currentEnd = nowUnix
            previousEnd = currentStart
            previousStart = currentStart - Int(thirtyDays)
            bucketSeconds = 86400
        }

        let conversationSteps = collectSteps(sinceUnix: previousStart)

        var curTokens = 0
        var prevTokens = 0
        var curInput = 0
        var curOutput = 0
        var curCache = 0
        var curSessions = Set<String>()
        var prevSessions = Set<String>()
        var bucketMap: [Int: Int] = [:]

        for (cid, steps) in conversationSteps {
            for step in steps {
                let ts = step.timestamp
                if ts >= currentStart && ts < currentEnd {
                    curTokens += step.totalTokens
                    curInput += step.inputTokens
                    curOutput += step.outputTokens
                    curCache += step.cacheReadTokens
                    curSessions.insert(cid)

                    let bucket = Int((Double(ts) + tzOffset) / Double(bucketSeconds))
                    bucketMap[bucket, default: 0] += step.totalTokens
                } else if ts >= previousStart && ts < previousEnd {
                    prevTokens += step.totalTokens
                    prevSessions.insert(cid)
                }
            }
        }

        let stats = GeminiStats(
            currentTokens: curTokens,
            previousTokens: prevTokens,
            currentSessions: curSessions.count,
            previousSessions: prevSessions.count,
            inputTokens: curInput,
            outputTokens: curOutput,
            cacheReadTokens: curCache
        )

        var points: [TrendPoint] = []
        var bucketStart = Int((Double(currentStart) + tzOffset) / Double(bucketSeconds))
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

        return (stats, points)
    }

    func fetchStats(for range: StatsTimeRange) -> GeminiStats {
        fetchStatsAndTrend(for: range).stats
    }

    func fetchTrend(for range: StatsTimeRange) -> [TrendPoint] {
        fetchStatsAndTrend(for: range).trend
    }

    /// Collect steps across eligible databases using the persistent disk cache
    /// Single-flight guard: `getEligibleDbFiles` stats every `.db` in the
    /// Antigravity tree, so a Dashboard reload and an agent panel opening
    /// together used to repeat the whole directory walk.
    private static let scanGate = ScanGate()

    private func collectSteps(sinceUnix: Int) -> [(cid: String, steps: [StepTokenUsage])] {
        Self.scanGate.run(key: "\(sinceUnix)") { collectStepsUncached(sinceUnix: sinceUnix) }
    }

    private func collectStepsUncached(sinceUnix: Int) -> [(cid: String, steps: [StepTokenUsage])] {
        let eligibleFiles = getEligibleDbFiles(since: sinceUnix)
        guard !eligibleFiles.isEmpty else { return [] }

        let diskCache = Self.getDiskCache()
        var results = [[(cid: String, steps: [StepTokenUsage])]](repeating: [], count: eligibleFiles.count)
        let newEntriesLock = NSLock()
        var newEntries: [String: DiskFileCacheEntry] = [:]

        DispatchQueue.concurrentPerform(iterations: eligibleFiles.count) { i in
            let f = eligibleFiles[i]
            if let entry = diskCache[f.path], entry.mtime == f.mtime && entry.size == f.size {
                let filtered = entry.steps.filter { $0.timestamp >= sinceUnix }
                results[i] = [(f.cid, filtered)]
            } else {
                let allSteps = queryStepsWithModels(from: f.path)
                let entry = DiskFileCacheEntry(mtime: f.mtime, size: f.size, steps: allSteps)
                newEntriesLock.lock()
                newEntries[f.path] = entry
                newEntriesLock.unlock()
                let filtered = allSteps.filter { $0.timestamp >= sinceUnix }
                results[i] = [(f.cid, filtered)]
            }
        }

        if !newEntries.isEmpty {
            Self.updateDiskCache(newEntries)
        }

        return results.flatMap { $0 }
    }

    /// Per-step usage records for the dashboard.
    func collectRecords(sinceUnix: Int) -> [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?, durationMs: Int?)] {
        let titles = conversationTitleMap()
        let conversationSteps = collectSteps(sinceUnix: sinceUnix)
        var records: [(tsMs: Int64, tokens: Int, freshInput: Int, cached: Int, output: Int, sessionId: String, model: String?, title: String?, durationMs: Int?)] = []
        for (cid, steps) in conversationSteps {
            for step in steps where step.timestamp >= sinceUnix {
                records.append((
                    tsMs: Int64(step.timestamp) * 1000,
                    tokens: step.totalTokens,
                    freshInput: step.inputTokens,
                    cached: step.cacheReadTokens,
                    output: step.outputTokens,
                    sessionId: cid,
                    model: step.model,
                    title: titles[cid],
                    durationMs: step.durationMs
                ))
            }
        }
        return records
    }

    /// conversation_id -> title, read once per service lifetime. Falls back
    /// to an immutable read when the summary DB is WAL-locked.
    private func conversationTitleMap() -> [String: String] {
        titleLock.lock()
        defer { titleLock.unlock() }
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

    // MARK: - Internal DB & Protobuf Scanning


    /// Read-only query with an immutable fallback: Antigravity keeps its DBs
    /// in WAL mode, and a plain READONLY connection cannot create/access the
    /// -shm file while the app holds them (prepare fails with rc 14). The
    /// immutable URI skips the WAL and reads the main file — possibly missing
    /// the newest un-checkpointed rows, which is acceptable for statistics.
    private func queryReadOnly(path: String, sql: String, row: (OpaquePointer) -> Void) {
        // Try the plain connection first; only fall back to the immutable URI
        // when the plain pass could not run at all (rc 14). A successful pass
        // must terminate the loop, or every row gets appended twice.
        for immutable in [false, true] {
            var handled = false
            queryReadOnly(path: path, immutable: immutable, sql: sql, row: { stmt in
                handled = true
                row(stmt)
            })
            if handled { return }
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
                model: model,
                durationMs: parsed.durationMs
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
    private func getEligibleDbFiles(since minUnix: Int) -> [DbFileMeta] {
        let minDate = Date(timeIntervalSince1970: TimeInterval(minUnix))
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: conversationsDir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return []
        }

        var results: [DbFileMeta] = []
        for file in files where file.pathExtension == "db" {
            let cid = file.deletingPathExtension().lastPathComponent
            let values = try? file.resourceValues(forKeys: keys)
            let mdate = values?.contentModificationDate
            let mtime = mdate?.timeIntervalSince1970 ?? 0
            let size = Int64(values?.fileSize ?? 0)

            if let mdate = mdate {
                if mdate >= minDate {
                    results.append(DbFileMeta(cid: cid, url: file, path: file.path, mtime: mtime, size: size))
                }
            } else {
                results.append(DbFileMeta(cid: cid, url: file, path: file.path, mtime: mtime, size: size))
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

    private func parseTimestampSubmessage<C: Collection>(_ bytes: C) -> (sec: Int, nanos: Int)? where C.Element == UInt8, C.Index == Int {
        var i = bytes.startIndex
        let end = bytes.endIndex
        var sec: Int? = nil
        var nanos = 0
        while i < end {
            guard let (k, nextI) = readVarint(bytes, from: i) else { break }
            i = nextI
            let fnum = k >> 3
            let wtype = k & 7
            if wtype == 0 {
                guard let (val, vNext) = readVarint(bytes, from: i) else { break }
                i = vNext
                if fnum == 1 { sec = Int(val) }
                else if fnum == 2 { nanos = Int(val) }
            } else if wtype == 2 {
                guard let (len, vNext) = readVarint(bytes, from: i) else { break }
                i = vNext + Int(len)
            } else if wtype == 1 { i += 8 }
            else if wtype == 5 { i += 4 }
            else { break }
        }
        guard let s = sec else { return nil }
        return (sec: s, nanos: nanos)
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

        // Parse CortexStepMetadata: field 1 (Timestamp), field 7/8 (Completed Timestamp), field 9 (ModelUsageStats)
        var mI = mRange.lowerBound
        let mEnd = mRange.upperBound
        var tsSec: Int? = nil
        var startTs: (sec: Int, nanos: Int)? = nil
        var endTs: (sec: Int, nanos: Int)? = nil
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
                let subSlice = bytes[mI..<(mI + length)]
                if fnum == 1 {
                    startTs = parseTimestampSubmessage(subSlice)
                    tsSec = startTs?.sec
                } else if fnum == 7 || fnum == 8 {
                    if endTs == nil {
                        endTs = parseTimestampSubmessage(subSlice)
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

        var durationMs: Int? = nil
        if let s = startTs, let e = endTs {
            let startMs = Int64(s.sec) * 1000 + Int64(s.nanos / 1_000_000)
            let endMs = Int64(e.sec) * 1000 + Int64(e.nanos / 1_000_000)
            let diff = endMs - startMs
            if diff >= 100 {
                durationMs = Int(diff)
            }
        }

        return StepTokenUsage(
            timestamp: ts,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            model: nil,
            durationMs: durationMs
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
