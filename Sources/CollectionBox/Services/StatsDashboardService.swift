import Foundation

enum StatsAgent: String, CaseIterable, Sendable {
    case codex, gemini, workbuddy, zcode, dsh

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Antigravity"
        case .workbuddy: return "WorkBuddy"
        case .zcode: return "ZCode"
        case .dsh: return "DSH"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .gemini: return "sparkles"
        case .workbuddy: return "briefcase.fill"
        case .zcode: return "chevron.left.forwardslash.fill"
        case .dsh: return "fish.fill"
        }
    }
}

struct UnifiedUsageRecord: Sendable {
    let agent: StatsAgent
    let model: String?      // nil → unknown-model bucket
    let title: String?
    let tsMs: Int64
    let tokens: Int         // total context throughput (input incl. cache + output)
    let freshInput: Int     // 0 when the source has no split (Codex)
    let cached: Int
    let output: Int
    let hasBreakdown: Bool  // false → only `tokens` is meaningful (Codex)
    let sessionId: String
}

/// Aggregates all three agents' local usage into one record stream for the
/// dashboard window. Collection runs off-main; each agent resolves on its own
/// schedule so the UI can fill in progressively. All stored services are
/// stateless, and callers only touch this from a single detached task each.
final class StatsDashboardService {
    static let shared = StatsDashboardService()
    private let codex = CodexStatsService()
    private let gemini = GeminiStatsService()
    private let workbuddy = WorkBuddyStatsService()
    private let zcode = ZCodeStatsService()
    private let dsh = DshStatsService()

    func collect(agent: StatsAgent, sinceMs: Int64) -> [UnifiedUsageRecord] {
        switch agent {
        case .codex:
            return codex.collectRecords(sinceUnix: Int(sinceMs / 1000)).map {
                UnifiedUsageRecord(agent: .codex, model: $0.model, title: $0.title, tsMs: $0.tsMs,
                                   tokens: $0.tokens, freshInput: 0, cached: 0, output: 0,
                                   hasBreakdown: false, sessionId: $0.sessionId)
            }
        case .gemini:
            return gemini.collectRecords(sinceUnix: Int(sinceMs / 1000)).map {
                UnifiedUsageRecord(agent: .gemini, model: $0.model, title: $0.title, tsMs: $0.tsMs,
                                   tokens: $0.tokens, freshInput: $0.freshInput, cached: $0.cached,
                                   output: $0.output, hasBreakdown: true, sessionId: $0.sessionId)
            }
        case .workbuddy:
            return workbuddy.collectRecords(sinceMs: sinceMs).map {
                UnifiedUsageRecord(agent: .workbuddy, model: $0.model, title: $0.title, tsMs: $0.tsMs,
                                   tokens: $0.tokens, freshInput: $0.freshInput, cached: $0.cached,
                                   output: $0.output, hasBreakdown: true, sessionId: $0.sessionId)
            }
        case .zcode:
            return zcode.collectRecords(sinceMs: sinceMs).map {
                UnifiedUsageRecord(agent: .zcode, model: $0.model, title: $0.title, tsMs: $0.tsMs,
                                   tokens: $0.tokens, freshInput: $0.freshInput, cached: $0.cached,
                                   output: $0.output, hasBreakdown: true, sessionId: $0.sessionId)
            }
        case .dsh:
            return dsh.collectRecords(sinceMs: sinceMs).map {
                UnifiedUsageRecord(agent: .dsh, model: $0.model, title: $0.title, tsMs: $0.tsMs,
                                   tokens: $0.tokens, freshInput: $0.freshInput, cached: $0.cached,
                                   output: $0.output, hasBreakdown: true, sessionId: $0.sessionId)
            }
        }
    }
}
