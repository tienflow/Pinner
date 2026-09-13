import Foundation

enum StatsAgent: String, CaseIterable, Sendable {
    case codex, gemini, workbuddy

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .workbuddy: return "WorkBuddy"
        }
    }
}

struct UnifiedUsageRecord: Sendable {
    let agent: StatsAgent
    let model: String?      // nil → unknown-model bucket
    let tsMs: Int64
    let tokens: Int
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

    func collect(agent: StatsAgent, sinceMs: Int64) -> [UnifiedUsageRecord] {
        switch agent {
        case .codex:
            return codex.collectRecords(sinceUnix: Int(sinceMs / 1000)).map {
                UnifiedUsageRecord(agent: .codex, model: $0.model, tsMs: $0.tsMs, tokens: $0.tokens, sessionId: $0.sessionId)
            }
        case .gemini:
            return gemini.collectRecords(sinceUnix: Int(sinceMs / 1000)).map {
                UnifiedUsageRecord(agent: .gemini, model: nil, tsMs: $0.tsMs, tokens: $0.tokens, sessionId: $0.sessionId)
            }
        case .workbuddy:
            return workbuddy.collectRecords(sinceMs: sinceMs).map {
                UnifiedUsageRecord(agent: .workbuddy, model: $0.model, tsMs: $0.tsMs, tokens: $0.tokens, sessionId: $0.sessionId)
            }
        }
    }
}
