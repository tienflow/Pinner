import Foundation
import SQLite3

/// Compact stats for one agent, mirroring WorkBuddyStats' field names so
/// AgentStatsView can render every agent uniformly.
struct AgentStats {
    let currentTokens: Int
    let previousTokens: Int
    let currentSessions: Int
    let previousSessions: Int
    let inputTokens: Int       // fresh input only (excludes cached reads)
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
        let input = inputTokens + cacheReadTokens
        guard input > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(input) * 100
    }

    var formattedTokens: String { WorkBuddyStats.formatTokens(currentTokens) }
    var formattedInput: String { WorkBuddyStats.formatTokens(inputTokens) }
    var formattedOutput: String { WorkBuddyStats.formatTokens(outputTokens) }
    var formattedCache: String { WorkBuddyStats.formatTokens(cacheReadTokens) }
    var formattedSessions: String { "\(currentSessions)" }
}

/// Unified stats/trend facade over the five agent services. Codex exposes no
/// breakdown, so its input/cache/output stay zero.
final class AgentStatsService {
    private let dashboard = StatsDashboardService.shared

    func fetchStats(agent: StatsAgent, for range: StatsTimeRange) -> AgentStats {
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

        let records = dashboard.collect(agent: agent, sinceMs: previousStartMs)
        var curTokens = 0, prevTokens = 0
        var curInput = 0, curOutput = 0, curCache = 0
        var curSessions = Set<String>(), prevSessions = Set<String>()

        for r in records {
            if r.tsMs >= currentStartMs && r.tsMs < currentEndMs {
                curTokens += r.tokens
                curInput += r.freshInput
                curOutput += r.output
                curCache += r.cached
                curSessions.insert(r.sessionId)
            } else if r.tsMs >= previousStartMs && r.tsMs < previousEndMs {
                prevTokens += r.tokens
                prevSessions.insert(r.sessionId)
            }
        }

        return AgentStats(
            currentTokens: curTokens,
            previousTokens: prevTokens,
            currentSessions: curSessions.count,
            previousSessions: prevSessions.count,
            inputTokens: curInput,
            outputTokens: curOutput,
            cacheReadTokens: curCache
        )
    }

    func fetchTrend(agent: StatsAgent, for range: StatsTimeRange) -> [TrendPoint] {
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

        let records = dashboard.collect(agent: agent, sinceMs: Int64(startUnix) * 1000)
        var bucketMap: [Int: Int] = [:]
        for r in records {
            let ts = Int(r.tsMs / 1000)
            if ts >= startUnix && ts < nowUnix {
                let bucket = Int((Double(ts) + tzOffset) / Double(bucketSeconds))
                bucketMap[bucket, default: 0] += r.tokens
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
}
