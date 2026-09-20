import Foundation

/// Structured result of LLM todo parsing.
struct ParsedTask: Equatable {
    var title: String
    var due: Date?
    /// EventKit raw priority: 0 none / 1 high / 5 medium / 9 low.
    var priority: Int
    var list: String?
    var fallback: Bool
}

/// Input context passed to the LLM: the raw sentence plus the reference time
/// and available reminder lists.
struct TodoPromptContext {
    var input: String
    var now: Date
    var lists: [String]
    var lastList: String?
}

enum TodoLLMError: LocalizedError {
    case notConfigured
    case badURL
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置待办 AI"
        case .badURL: return "Base URL 无效"
        case .httpStatus(let code): return "模型端点返回 HTTP \(code)"
        }
    }
}

/// OpenAI-compatible `/chat/completions` client with a 5s timeout.
/// The response body parse is a pure function (`parseResponse`) so it can be
/// unit-tested without a network.
struct TodoLLMClient {
    var session: URLSession
    var timeout: TimeInterval = 5

    init(session: URLSession = .shared, timeout: TimeInterval = 5) {
        self.session = session
        self.timeout = timeout
    }

    /// Pure parse of a `/chat/completions` response body.
    /// Returns nil when the body cannot be interpreted as our JSON schema
    /// (which triggers the caller's fallback path).
    static func parseResponse(_ data: Data) -> ParsedTask? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // Tolerant parsing: strip markdown fences, then take the first {...}
        // balanced region.
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(cleaned[start...end])
        guard let jsonData = json.data(using: .utf8) else { return nil }

        struct Raw: Decodable {
            let title: String?
            let due: String?
            let priority: Int?
            let list: String?
            let fallback: Bool?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: jsonData) else { return nil }

        let due: Date?
        if let dueStr = raw.due, !dueStr.isEmpty {
            due = ISO8601DateFormatter().date(from: dueStr)
        } else {
            due = nil
        }

        let priority: Int
        if let rawPriority = raw.priority, [0, 1, 5, 9].contains(rawPriority) {
            priority = rawPriority
        } else {
            priority = 0
        }

        return ParsedTask(
            title: raw.title ?? "",
            due: due,
            priority: priority,
            list: raw.list,
            fallback: raw.fallback ?? false
        )
    }

    /// Calls the configured OpenAI-compatible endpoint. Returns nil when the
    /// body is unparseable (caller falls back to storing the raw text);
    /// throws on network / timeout / HTTP errors.
    func parse(context: TodoPromptContext, config: TodoLLMConfig) async throws -> ParsedTask? {
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw TodoLLMError.notConfigured
        }
        let (system, user) = TodoPrompt.build(
            input: context.input, now: context.now,
            lists: context.lists, lastList: context.lastList
        )
        let url: URL
        if config.baseURL.hasSuffix("/chat/completions") {
            url = URL(string: config.baseURL)!
        } else {
            let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
            url = URL(string: base + "/chat/completions")!
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TodoLLMError.httpStatus(http.statusCode)
        }
        return Self.parseResponse(data)
    }
}