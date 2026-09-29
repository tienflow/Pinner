import Foundation

/// TypeSafe Jev (System One) semantic router for Apple Notes fleeting capture.
/// Uses calibrated Choice questions and speculative fan-out to route thoughts
/// directly to the user's real folders and notes with high precision.
public struct TypeSafeJevClient: Sendable {
    /// A candidate choice with its model probability score.
    public struct JevCandidate: Sendable, Equatable {
        public var name: String
        public var probability: Double

        public init(name: String, probability: Double) {
            self.name = name
            self.probability = probability
        }
    }

    /// Detailed routing evaluation result containing calibrated confidence and candidate distributions.
    public struct JevRouteResult: Sendable, Equatable {
        public var parsed: ParsedFleetingThought
        public var folderConfidence: Double
        public var noteConfidence: Double
        public var topFolders: [JevCandidate]
        public var topNotes: [JevCandidate]

        public var isHighConfidence: Bool {
            folderConfidence >= 0.65 && noteConfidence >= 0.40
        }

        public init(
            parsed: ParsedFleetingThought,
            folderConfidence: Double,
            noteConfidence: Double,
            topFolders: [JevCandidate] = [],
            topNotes: [JevCandidate] = []
        ) {
            self.parsed = parsed
            self.folderConfidence = folderConfidence
            self.noteConfidence = noteConfidence
            self.topFolders = topFolders
            self.topNotes = topNotes
        }
    }

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves TypeSafe credentials from UserDefaults, environment, or skill config.
    public static func resolveConfig() -> (apiKey: String, baseURL: String, model: String)? {
        let defaults = UserDefaults.standard
        let udKey = defaults.string(forKey: "TypeSafe.apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let udKey, !udKey.isEmpty {
            let udURL = defaults.string(forKey: "TypeSafe.baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let udModel = defaults.string(forKey: "TypeSafe.model")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                apiKey: udKey,
                baseURL: (udURL?.isEmpty == false) ? udURL! : "https://api.typesafe.ai/v1",
                model: (udModel?.isEmpty == false) ? udModel! : "jev-latest"
            )
        }

        if let envKey = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envKey.isEmpty {
            let envURL = ProcessInfo.processInfo.environment["TYPESAFE_BASE_URL"] ?? "https://api.typesafe.ai/v1"
            let envModel = ProcessInfo.processInfo.environment["TYPESAFE_MODEL"] ?? "jev-latest"
            return (apiKey: envKey, baseURL: envURL, model: envModel)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configPath = home.appendingPathComponent(".gemini/config/skills/typesafe-ai/config.json")
        if let data = try? Data(contentsOf: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let fileKey = obj["api_key"] as? String, !fileKey.isEmpty {
            let fileURL = (obj["base_url"] as? String) ?? "https://api.typesafe.ai/v1"
            let fileModel = (obj["default_model"] as? String) ?? "jev-latest"
            return (apiKey: fileKey, baseURL: fileURL, model: fileModel)
        }

        return nil
    }

    /// Tests connection and model evaluation using a lightweight dummy question.
    public static func testConnection(baseURL: String, apiKey: String, model: String) async throws -> String {
        let bURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let mod = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bURL.isEmpty, !key.isEmpty, !mod.isEmpty else {
            throw NSError(domain: "TypeSafeJev", code: 400, userInfo: [NSLocalizedDescriptionKey: "请先填齐 Base URL、API Key 与模型名"])
        }

        guard var comps = URLComponents(string: bURL) else {
            throw NSError(domain: "TypeSafeJev", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])
        }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/v1/systemone"
        } else if !comps.path.hasSuffix("/systemone") {
            comps.path = (comps.path as NSString).appendingPathComponent("systemone")
        }
        guard let url = comps.url else {
            throw NSError(domain: "TypeSafeJev", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的端点地址"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "state": "测试连接：闪念投递测试语句",
            "model": mod,
            "questions": [
                "ping": [
                    "type": "choice",
                    "instructions": "语句类型是什么？",
                    "criteria": [
                        "test": "测试验证语句",
                        "other": "其他语句"
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: sessionConfig)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TypeSafeJev", code: -1, userInfo: [NSLocalizedDescriptionKey: "无网络响应"])
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw NSError(domain: "TypeSafeJev", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "认证失败 (HTTP \(http.statusCode))，请检查 API Key"])
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TypeSafeJev", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "端点返回 HTTP \(http.statusCode): \(bodyStr.prefix(100))"])
        }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let answers = root["answers"] as? [String: [String: Any]],
           let pingAnswer = answers["ping"],
           let choice = pingAnswer["choice"] as? String {
            return "连接成功，Jev 响应正常 (选择: \(choice))"
        }

        return "连接成功，端点响应有效"
    }

    /// Evaluates user input against folderTree using Jev System One questions, returning detailed confidence and distribution.
    public func evaluate(context: FleetingPrompt.Context, config: (apiKey: String, baseURL: String, model: String)) async throws -> JevRouteResult? {
        let trimmed = context.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tree = context.folderTree.filter { $0.name != "Recently Deleted" && $0.name != "最近删除" && $0.name != "Notes" }
        guard !tree.isEmpty else { return nil }

        // 1. Build folder rubric
        var folderCriteria: [String: String] = [:]
        for item in tree {
            switch item.name {
            case "清醒备忘":
                folderCriteria[item.name] = "情绪反思、亲密关系复盘、戒断与认知重塑、日常打卡/天数记录、断联日志"
            case "装修笔记":
                folderCriteria[item.name] = "全屋尺寸、电路布局、家具定制方案、装修材料与施工"
            case "妙笔偶得":
                folderCriteria[item.name] = "生活闲思、金句警句、读书体验摘抄、灵感短句"
            case "有感而发":
                folderCriteria[item.name] = "长篇随笔感悟、生活大事件记录、人生独处思考、深度心得"
            case "日积月累":
                folderCriteria[item.name] = "专业知识点、速查表、3D打印参数、驾驶技术、实用技能"
            case "生活台账":
                folderCriteria[item.name] = "个人档案、健康体检、资产账单、借款贷款、生活数据"
            default:
                if !item.notes.isEmpty {
                    folderCriteria[item.name] = "包含已有笔记: " + item.notes.prefix(6).joined(separator: "、")
                } else {
                    folderCriteria[item.name] = "备忘录分类：\(item.name)"
                }
            }
        }

        // 2. Build speculative note questions for each folder
        var questions: [String: Any] = [
            "target_folder": [
                "type": "choice",
                "instructions": "用户这段随笔应归类到哪个备忘录分类文件夹？",
                "criteria": folderCriteria
            ],
            "mode": [
                "type": "choice",
                "instructions": "这段文字应如何插入备忘录？",
                "criteria": [
                    "prepend": "打卡日志、天数记录，需要倒序置顶插入在最上方",
                    "append": "普通随笔、条目或感悟，追加在最末尾",
                    "create": "全新独立文章或笔记，现有笔记均不合适"
                ]
            ]
        ]

        // 2. Identify plausible folders for speculative note evaluation (limit to max 3 folders to keep latency < 1s)
        var candidateFolders: [AppleNotesService.FolderItem] = []
        for item in tree where !item.notes.isEmpty {
            let matchesKeyword = trimmed.contains(item.name) ||
                (item.name == "清醒备忘" && (trimmed.contains("断联") || trimmed.contains("情绪") || trimmed.contains("戒断") || trimmed.contains("执念") || trimmed.contains("打卡") || trimmed.contains("日志") || trimmed.contains("天"))) ||
                (item.name == "装修笔记" && (trimmed.contains("装修") || trimmed.contains("尺寸") || trimmed.contains("家具") || trimmed.contains("电路"))) ||
                (item.name == "生活台账" && (trimmed.contains("买") || trimmed.contains("贷") || trimmed.contains("健康") || trimmed.contains("体检") || trimmed.contains("档案"))) ||
                (item.name == "日积月累" && (trimmed.contains("速查") || trimmed.contains("技巧") || trimmed.contains("打印") || trimmed.contains("参数")))
            if matchesKeyword {
                candidateFolders.append(item)
            }
        }

        if candidateFolders.isEmpty {
            if let lastF = context.lastFolder, let matched = tree.first(where: { $0.name == lastF && !$0.notes.isEmpty }) {
                candidateFolders.append(matched)
            }
            for item in tree where !item.notes.isEmpty && !candidateFolders.contains(where: { $0.name == item.name }) {
                candidateFolders.append(item)
                if candidateFolders.count >= 2 { break }
            }
        }

        for item in candidateFolders.prefix(3) {
            var noteCriteria: [String: String] = [:]
            for note in item.notes.prefix(12) {
                noteCriteria[note] = "已有备忘录：《\(note)》"
            }
            noteCriteria["新建独立笔记"] = "不属于上述任何已有备忘录，应在该分类下新建笔记"

            questions["note_\(item.name)"] = [
                "type": "choice",
                "instructions": "如果归属于「\(item.name)」，最适合追加到哪篇已有备忘录？",
                "criteria": noteCriteria
            ]
        }

        guard var comps = URLComponents(string: config.baseURL) else { return nil }
        if comps.path.isEmpty || comps.path == "/" {
            comps.path = "/v1/systemone"
        } else if !comps.path.hasSuffix("/systemone") {
            comps.path = (comps.path as NSString).appendingPathComponent("systemone")
        }
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "state": trimmed,
            "model": config.model,
            "questions": questions
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 4.0
        let reqSession = URLSession(configuration: sessionConfig)

        let (data, response) = try await reqSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        return Self.decodeJevResult(data, originalInput: trimmed, tree: tree)
    }

    /// Evaluates user input against folderTree using Jev System One questions, returning parsed model.
    public func route(context: FleetingPrompt.Context, config: (apiKey: String, baseURL: String, model: String)) async throws -> ParsedFleetingThought? {
        try await evaluate(context: context, config: config)?.parsed
    }

    /// Pure decoder for TypeSafe Jev System One evaluation response with full confidence details.
    public static func decodeJevResult(_ data: Data, originalInput: String, tree: [AppleNotesService.FolderItem]) -> JevRouteResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: [String: Any]] else {
            return nil
        }

        guard let folderAnswer = answers["target_folder"],
              let selectedFolder = folderAnswer["choice"] as? String else {
            return nil
        }

        let folderConfidence = (folderAnswer["confidence"] as? Double) ?? 0.9

        var topFolders: [JevCandidate] = []
        if let probs = folderAnswer["probabilities"] as? [String: Double] {
            topFolders = probs.sorted { $0.value > $1.value }.map { JevCandidate(name: $0.key, probability: $0.value) }
        }

        // Read speculative note choice
        var targetNote = "日常随笔"
        var isCreateNew = false
        var noteConfidence: Double = 0.9
        var topNotes: [JevCandidate] = []

        if let noteAnswer = answers["note_\(selectedFolder)"],
           let chosenNote = noteAnswer["choice"] as? String {
            noteConfidence = (noteAnswer["confidence"] as? Double) ?? 0.9
            if let probs = noteAnswer["probabilities"] as? [String: Double] {
                topNotes = probs.sorted { $0.value > $1.value }.map { JevCandidate(name: $0.key, probability: $0.value) }
            }
            if chosenNote == "新建独立笔记" {
                isCreateNew = true
                targetNote = String(originalInput.prefix(15))
            } else {
                targetNote = chosenNote
            }
        } else {
            let matchedFolderNotes = tree.first(where: { $0.name == selectedFolder })?.notes ?? []
            targetNote = matchedFolderNotes.first ?? "日常随笔"
        }

        // Read insertion mode
        var mode: NoteInsertionMode = .append
        if isCreateNew {
            mode = .create
        } else if let modeAnswer = answers["mode"],
                  let modeChoice = modeAnswer["choice"] as? String {
            if modeChoice == "prepend" || targetNote.contains("日志") || targetNote.contains("打卡") {
                mode = .prepend
            } else if modeChoice == "create" {
                mode = .create
            } else {
                mode = .append
            }
        } else if targetNote.contains("日志") || targetNote.contains("打卡") {
            mode = .prepend
        }

        let formatted = originalInput
        let combinedConfidence = min(folderConfidence, noteConfidence)

        let parsed = ParsedFleetingThought(
            folder: selectedFolder,
            targetNoteTitle: targetNote,
            mode: mode,
            formattedContent: formatted,
            confidence: combinedConfidence,
            fallback: false
        )

        return JevRouteResult(
            parsed: parsed,
            folderConfidence: folderConfidence,
            noteConfidence: noteConfidence,
            topFolders: topFolders,
            topNotes: topNotes
        )
    }

    /// Pure decoder for TypeSafe Jev System One evaluation response.
    public static func decodeJevResponse(_ data: Data, originalInput: String, tree: [AppleNotesService.FolderItem]) -> ParsedFleetingThought? {
        decodeJevResult(data, originalInput: originalInput, tree: tree)?.parsed
    }
}
