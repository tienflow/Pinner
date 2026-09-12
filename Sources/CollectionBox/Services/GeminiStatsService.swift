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

    // MARK: - Internal DB & Protobuf Scanning

    private struct StepTokenUsage {
        let timestamp: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int

        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens
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
        guard let db = openDB(at: dbPath) else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT step_payload FROM steps WHERE step_type = 15;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var usages: [StepTokenUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let length = Int(sqlite3_column_bytes(stmt, 0))
                let buffer = UnsafeBufferPointer(start: blob.assumingMemoryBound(to: UInt8.self), count: length)
                if let parsed = parseProtobufStep(buffer) {
                    usages.append(parsed)
                }
            }
        }
        return usages
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
            cacheReadTokens: cacheReadTokens
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
