import Foundation

public struct ParsedFleetingThought: Equatable, Sendable {
    public var folder: String
    public var targetNoteTitle: String
    public var mode: NoteInsertionMode
    public var formattedContent: String
    public var confidence: Double
    public var fallback: Bool

    public init(
        folder: String,
        targetNoteTitle: String,
        mode: NoteInsertionMode,
        formattedContent: String,
        confidence: Double = 1.0,
        fallback: Bool = false
    ) {
        self.folder = folder
        self.targetNoteTitle = targetNoteTitle
        self.mode = mode
        self.formattedContent = formattedContent
        self.confidence = confidence
        self.fallback = fallback
    }
}

public enum FleetingLLMError: LocalizedError {
    case notConfigured
    case badURL
    case httpStatus(Int)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置待办/闪念 AI"
        case .badURL: return "API Base URL 无效"
        case .httpStatus(let code): return "模型端点返回 HTTP \(code)"
        case .parseFailed(let reason): return "解析模型输出失败：\(reason)"
        }
    }
}

public struct FleetingThoughtLLMClient {
    public var session: URLSession
    public var timeout: TimeInterval

    public init(session: URLSession? = nil, timeout: TimeInterval = 25) {
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

    public static func extractCandidateText(from data: Data) -> String? {
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
            return content
        }
        return String(data: data, encoding: .utf8)
    }

    public static func stripReasoningTags(_ text: String) -> String {
        var cleaned = text
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>", options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                options: [],
                range: NSRange(location: 0, length: cleaned.utf16.count),
                withTemplate: ""
            )
        }
        return cleaned
    }

    /// Parse raw LLM output or OpenAI envelope into ParsedFleetingThought.
    public static func parseResponse(_ data: Data, defaultInput: String = "") -> ParsedFleetingThought? {
        guard let rawText = extractCandidateText(from: data) else { return nil }

        // Strip <think>...</think> reasoning tags
        var cleaned = stripReasoningTags(rawText)
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8) else { return nil }

        struct RawJSON: Decodable {
            let folder: String?
            let targetNoteTitle: String?
            let mode: String?
            let formattedContent: String?
            let confidence: Double?
        }

        guard let decoded = try? JSONDecoder().decode(RawJSON.self, from: jsonData) else {
            return nil
        }

        let folder = (decoded.folder ?? "").trimmingCharacters(in: .whitespaces)
        let title = (decoded.targetNoteTitle ?? "").trimmingCharacters(in: .whitespaces)
        let modeStr = (decoded.mode ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let mode: NoteInsertionMode
        switch modeStr {
        case "prepend": mode = .prepend
        case "create": mode = .create
        default: mode = .append
        }

        let content = decoded.formattedContent ?? defaultInput

        return ParsedFleetingThought(
            folder: folder.isEmpty ? "Notes" : folder,
            targetNoteTitle: title.isEmpty ? "灵感闪念" : title,
            mode: mode,
            formattedContent: content,
            confidence: decoded.confidence ?? 0.9,
            fallback: false
        )
    }

    /// Primary entry point: parse context using confidence-gated Jev System One + LLM deep arbitration.
    public func parse(context: FleetingPrompt.Context, config: TodoLLMConfig) async throws -> ParsedFleetingThought {
        // 1. Evaluate with TypeSafe Jev System One (calibrated, deterministic, sub-second)
        var jevResult: TypeSafeJevClient.JevRouteResult? = nil
        if let jevConfig = TypeSafeJevClient.resolveConfig() {
            let jevClient = TypeSafeJevClient(session: session)
            jevResult = try? await jevClient.evaluate(context: context, config: jevConfig)
        }

        // 2. High confidence threshold: if Jev is confident (>= 0.82 folder, >= 0.75 note), direct hit!
        if let jev = jevResult, jev.isHighConfidence {
            return jev.parsed
        }

        // 3. Low confidence or ambiguity: escalate to LLM deep arbitration if standard LLM is configured
        let hasLLM = !config.baseURL.isEmpty && !config.apiKey.isEmpty && !config.model.isEmpty
        if hasLLM {
            if let jev = jevResult {
                // LLM arbitration with Jev's candidate distribution as prior context
                if let arbitrated = try? await arbitrateWithLLM(context: context, jevResult: jev, config: config) {
                    return arbitrated
                }
                // If arbitration failed, fall back to Jev's best guess
                return jev.parsed
            } else {
                // No Jev available, pure standard LLM parse
                if let parsed = try? await callOpenAIParse(context: context, config: config) {
                    return parsed
                }
            }
        } else if let jev = jevResult {
            // No LLM configured, but Jev returned something: use Jev's evaluation
            return jev.parsed
        }

        // 4. Fall back to local heuristic
        return Self.localFallback(context: context)
    }

    /// Arbitrates ambiguous or low-confidence thoughts using standard LLM with Jev's candidate distribution as prior context.
    private func arbitrateWithLLM(
        context: FleetingPrompt.Context,
        jevResult: TypeSafeJevClient.JevRouteResult,
        config: TodoLLMConfig
    ) async throws -> ParsedFleetingThought? {
        guard var comps = URLComponents(string: config.baseURL) else { return nil }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/v1/chat/completions"
        } else if !comps.path.hasSuffix("/chat/completions") {
            comps.path = (comps.path as NSString).appendingPathComponent("chat/completions")
        }
        guard let url = comps.url else { return nil }

        let systemPrompt = """
        你是个人备忘录（Apple Notes）的高级意图识别与决策专家。
        初筛引擎（Jev）对用户的随笔进行了第一轮意图识别，置信度较低或存在歧义。
        请结合用户原文、备忘录架构与初筛推荐，做出最终裁决，输出严格符合以下结构的合法 JSON（不要包含任何代码块标记或额外说明）：
        {
          "folder": "精确匹配已有分类名",
          "targetNoteTitle": "目标笔记标题",
          "mode": "append|prepend|create",
          "formattedContent": "排版好的正文内容",
          "confidence": 0.95
        }

        【裁决铁律】：
        1. folder 必须是已有分类列表中真实存在的一个，严禁捏造；
        2. targetNoteTitle：若不是新建独立笔记，必须严格从该分类已有的笔记中挑选最贴切的一篇；若现有笔记均不合适，mode 必须设为 create 并拟定新笔记标题；
        3. 模式规则：
           - prepend（倒序置顶插入）：打卡、日志、天数记录、即时心情追踪；
           - append（尾部追加）：普通随笔、灵感短语、读书摘抄、知识积累；
           - create（新建独立笔记）：全新长文、独立主题随笔。
        """

        var jevPriorSummary = "- 初筛推荐分类：\(jevResult.parsed.folder)（置信度: \(Int(jevResult.folderConfidence * 100))%）"
        if !jevResult.topFolders.isEmpty {
            let topF = jevResult.topFolders.prefix(3).map { "\($0.name) (\(Int($0.probability * 100))%)" }.joined(separator: "、")
            jevPriorSummary += "\n  候选分类概率分布：\(topF)"
        }
        jevPriorSummary += "\n- 初筛推荐笔记：\(jevResult.parsed.targetNoteTitle)（置信度: \(Int(jevResult.noteConfidence * 100))%）"
        if !jevResult.topNotes.isEmpty {
            let topN = jevResult.topNotes.prefix(3).map { "\($0.name) (\(Int($0.probability * 100))%)" }.joined(separator: "、")
            jevPriorSummary += "\n  候选笔记概率分布：\(topN)"
        }
        jevPriorSummary += "\n- 初筛建议模式：\(jevResult.parsed.mode.rawValue)"

        let treeDesc = context.folderTree
            .filter { $0.name != "Recently Deleted" && $0.name != "最近删除" }
            .map { f in
                let notesList = f.notes.isEmpty ? "(无笔记)" : f.notes.prefix(12).joined(separator: "、")
                return "📁 [\(f.name)]: \(notesList)"
            }
            .joined(separator: "\n")

        let userPrompt = """
        【用户输入的随笔原文】：
        \(context.input)

        【初筛引擎（Jev）分析先验】：
        \(jevPriorSummary)

        【用户备忘录的分类与现有笔记】：
        \(treeDesc)
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        guard let parsed = Self.parseResponse(data, defaultInput: context.input) else {
            return nil
        }

        // Anti-hallucination sanitization: ensure folder exists in tree
        let validFolders = context.folderTree.map(\.name)
        let finalFolder: String
        if validFolders.contains(parsed.folder) {
            finalFolder = parsed.folder
        } else if let fuzzy = validFolders.first(where: { $0.contains(parsed.folder) || parsed.folder.contains($0) }) {
            finalFolder = fuzzy
        } else {
            finalFolder = jevResult.parsed.folder
        }

        // Anti-hallucination sanitization: ensure note exists if not create
        var finalNote = parsed.targetNoteTitle
        if parsed.mode != .create {
            let availableNotes = context.folderTree.first(where: { $0.name == finalFolder })?.notes ?? []
            if !availableNotes.contains(finalNote) {
                if let fuzzyNote = availableNotes.first(where: { $0.contains(finalNote) || finalNote.contains($0) }) {
                    finalNote = fuzzyNote
                } else if availableNotes.contains(jevResult.parsed.targetNoteTitle) {
                    finalNote = jevResult.parsed.targetNoteTitle
                } else {
                    finalNote = availableNotes.first ?? finalNote
                }
            }
        }

        return ParsedFleetingThought(
            folder: finalFolder,
            targetNoteTitle: finalNote,
            mode: parsed.mode,
            formattedContent: context.input,
            confidence: max(parsed.confidence, 0.92),
            fallback: false
        )
    }

    /// Pure standard LLM parse when Jev is unavailable.
    private func callOpenAIParse(context: FleetingPrompt.Context, config: TodoLLMConfig) async throws -> ParsedFleetingThought? {
        let (systemPrompt, userPrompt) = FleetingPrompt.build(context: context)

        guard var comps = URLComponents(string: config.baseURL) else {
            throw FleetingLLMError.badURL
        }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/v1/chat/completions"
        } else if !comps.path.hasSuffix("/chat/completions") {
            comps.path = (comps.path as NSString).appendingPathComponent("chat/completions")
        }
        guard let url = comps.url else { throw FleetingLLMError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        return Self.parseResponse(data, defaultInput: context.input)
    }

    /// Polishes user's fleeting thought: fixes typos and improves phrasing while preserving 100% meaning and voice.
    public func polish(text: String, config: TodoLLMConfig) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw FleetingLLMError.notConfigured
        }

        let systemPrompt = """
        你是随笔与闪念记录的文字精修助手。请对用户的随笔或闪念进行轻量、克制的文字润色：
        1. 修正错别字、语病与不恰当的标点符号；
        2. 提升语言的流畅度与凝练感，消除口头赘语与语病杂质；
        3. 必须绝对保真用户的情感、事实与原始意图，严禁过度修辞、自我感动、扩写或添加说教；
        4. 直接返回润色后的正文，严禁输出任何思考标记（如 <think>）、多余说明或 Markdown 代码块引用。
        """

        guard var comps = URLComponents(string: config.baseURL) else {
            throw FleetingLLMError.badURL
        }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/v1/chat/completions"
        } else if !comps.path.hasSuffix("/chat/completions") {
            comps.path = (comps.path as NSString).appendingPathComponent("chat/completions")
        }
        guard let url = comps.url else { throw FleetingLLMError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed]
            ]
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FleetingLLMError.httpStatus(http.statusCode)
        }

        if let raw = Self.extractCandidateText(from: data) {
            var cleaned = Self.stripReasoningTags(raw)
            cleaned = cleaned
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return trimmed
    }

    /// Local rule-based fallback when offline or LLM unavailable.
    public static func localFallback(context: FleetingPrompt.Context) -> ParsedFleetingThought {
        let trimmed = context.input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if matching log/diary pattern (e.g. 日志, 打卡, 断联)
        let isLogPattern = trimmed.contains("断联") ||
                           trimmed.contains("打卡") ||
                           trimmed.contains("日志") ||
                           trimmed.range(of: #"第\s*\d+\s*天"#, options: .regularExpression) != nil ||
                           context.lastNote?.contains("日志") == true

        if isLogPattern {
            let targetFolder = context.lastFolder ?? context.folderTree.first(where: { $0.name.contains("清醒") })?.name ?? "清醒备忘"
            let matchingNotes = context.folderTree.first(where: { $0.name == targetFolder })?.notes ?? []
            let targetNote = context.lastNote ?? matchingNotes.first(where: { $0.contains("日志") }) ?? matchingNotes.first ?? "日常日志"

            return ParsedFleetingThought(
                folder: targetFolder,
                targetNoteTitle: targetNote,
                mode: .prepend,
                formattedContent: trimmed,
                confidence: 0.9,
                fallback: true
            )
        }

        // Regular thought fallback
        var targetFolder = context.lastFolder
        let targetNote = context.lastNote

        if targetFolder == nil {
            if trimmed.contains("装修") || trimmed.contains("尺寸") || trimmed.contains("家具") || trimmed.contains("电路") {
                targetFolder = context.folderTree.first(where: { $0.name.contains("装修") })?.name
            } else if trimmed.contains("断联") || trimmed.contains("情绪") || trimmed.contains("戒断") || trimmed.contains("认知") || trimmed.contains("执念") {
                targetFolder = context.folderTree.first(where: { $0.name.contains("清醒") })?.name
            } else if trimmed.contains("买") || trimmed.contains("贷") || trimmed.contains("健康") || trimmed.contains("档案") || trimmed.contains("体检") {
                targetFolder = context.folderTree.first(where: { $0.name.contains("台账") })?.name
            } else if trimmed.contains("模型") || trimmed.contains("速查") || trimmed.contains("技巧") || trimmed.contains("打印") {
                targetFolder = context.folderTree.first(where: { $0.name.contains("日积月累") })?.name
            } else if trimmed.count > 40 {
                targetFolder = context.folderTree.first(where: { $0.name.contains("有感而发") })?.name
            } else {
                targetFolder = context.folderTree.first(where: { $0.name.contains("妙笔偶得") })?.name
            }
        }

        let fallbackFolder = targetFolder ?? context.folderTree.first(where: { $0.name != "Notes" && $0.name != "Recently Deleted" })?.name ?? context.folders.first ?? "有感而发"
        let matchingNotes = context.folderTree.first(where: { $0.name == fallbackFolder })?.notes ?? []
        let fallbackNote = targetNote ?? matchingNotes.first ?? "日常随笔"

        return ParsedFleetingThought(
            folder: fallbackFolder,
            targetNoteTitle: fallbackNote,
            mode: .append,
            formattedContent: trimmed,
            confidence: 0.8,
            fallback: true
        )
    }
}
