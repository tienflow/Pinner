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

/// OpenAI-compatible `/chat/completions` client with a 30s timeout.
/// The response body parse is a pure function (`parseResponse`) so it can be
/// unit-tested without a network.
struct TodoLLMClient {
    var session: URLSession
    var timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 30) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: config)
        }
    }

    /// Pure parse of a `/chat/completions` response body (or direct JSON payload).
    /// Returns nil when the body cannot be interpreted as our JSON schema
    /// (which triggers the caller's fallback path).
    static func parseResponse(_ data: Data) -> ParsedTask? {
        // Step 1: Extract candidate JSON text.
        // First try standard OpenAI /chat/completions schema: choices[0].message.content
        var candidateText: String?
        struct ChatMessage: Decodable {
            let content: String?
        }
        struct ChatChoice: Decodable {
            let message: ChatMessage?
        }
        struct ChatEnvelope: Decodable {
            let choices: [ChatChoice]?
        }

        if let envelope = try? JSONDecoder().decode(ChatEnvelope.self, from: data),
           let content = envelope.choices?.first?.message?.content,
           !content.isEmpty {
            candidateText = content
        } else {
            // Otherwise, treat the data as a direct string (e.g. test mock or direct JSON)
            candidateText = String(data: data, encoding: .utf8)
        }

        guard let rawText = candidateText else { return nil }

        // Step 2: Strip reasoning tags like <think>...</think> (e.g. DeepSeek R1)
        var cleaned = rawText
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(location: 0, length: cleaned.utf16.count),
                withTemplate: ""
            )
        }

        // Strip markdown code fences
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")

        // Find the outer balanced {...} region
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(cleaned[start...end])
        guard let jsonData = json.data(using: .utf8) else { return nil }

        struct AnyPriority: Decodable {
            var value: Int = 0
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let i = try? container.decode(Int.self) {
                    switch i {
                    case 1...4: value = 1
                    case 5...8: value = 5
                    case 9:     value = 9
                    default:    value = 0
                    }
                } else if let s = try? container.decode(String.self) {
                    let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if lower.contains("1") || lower.contains("high") || lower.contains("urgent") || lower.contains("高") || lower.contains("重") || lower.contains("急") || lower.contains("p0") || lower.contains("p1") {
                        value = 1
                    } else if lower.contains("5") || lower.contains("med") || lower.contains("中") || lower.contains("普") || lower.contains("常") || lower.contains("p2") {
                        value = 5
                    } else if lower.contains("9") || lower.contains("low") || lower.contains("低") || lower.contains("缓") || lower.contains("p3") {
                        value = 9
                    } else if let parsedInt = Int(lower) {
                        switch parsedInt {
                        case 1...4: value = 1
                        case 5...8: value = 5
                        case 9:     value = 9
                        default:    value = 0
                        }
                    } else {
                        value = 0
                    }
                } else {
                    value = 0
                }
            }
        }

        struct Raw: Decodable {
            let title: String?
            let due: String?
            let priority: AnyPriority?
            let list: String?
            let fallback: Bool?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: jsonData) else { return nil }

        let due: Date?
        if let dueStr = raw.due?.trimmingCharacters(in: .whitespacesAndNewlines), !dueStr.isEmpty {
            due = parseDate(dueStr)
        } else {
            due = nil
        }

        let priority = raw.priority?.value ?? 0

        let listName: String?
        if let rawList = raw.list?.trimmingCharacters(in: .whitespacesAndNewlines), !rawList.isEmpty {
            let lower = rawList.lowercased()
            if ["null", "nil", "none", "默认", "无"].contains(lower) {
                listName = nil
            } else {
                listName = rawList
            }
        } else {
            listName = nil
        }

        let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ParsedTask(
            title: title,
            due: due,
            priority: priority,
            list: listName,
            fallback: raw.fallback ?? false
        )
    }

    /// Flexible date parser supporting various ISO8601 and common datetime strings.
    static func parseDate(_ string: String) -> Date? {
        let isoWithTimezone = ISO8601DateFormatter()
        isoWithTimezone.formatOptions = [.withInternetDateTime]
        if let d = isoWithTimezone.date(from: string) { return d }

        let isoWithMillis = ISO8601DateFormatter()
        isoWithMillis.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoWithMillis.date(from: string) { return d }

        // Fallback formatters for models omitting colon in timezone or space separated
        let formatPatterns = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for pattern in formatPatterns {
            df.dateFormat = pattern
            if let d = df.date(from: string) { return d }
        }
        return nil
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

        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if trimmedBase.hasSuffix("/chat/completions") {
            urlString = trimmedBase
        } else {
            let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
            urlString = base + "/chat/completions"
        }

        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw TodoLLMError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0,
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