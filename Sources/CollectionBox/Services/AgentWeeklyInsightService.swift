import Foundation

struct AgentWeeklyInsight: Identifiable, Sendable, Codable {
    let id: UUID
    let title: String
    let summary: String
    let contentMarkdown: String
    let includedSources: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        contentMarkdown: String,
        includedSources: [String] = ["Agent"],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.contentMarkdown = contentMarkdown
        self.includedSources = includedSources
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, contentMarkdown, includedSources, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        contentMarkdown = try c.decode(String.self, forKey: .contentMarkdown)
        includedSources = try c.decodeIfPresent([String].self, forKey: .includedSources) ?? ["Agent"]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum WeeklyInsightError: LocalizedError {
    case notConfigured
    case badURL
    case httpStatus(Int)
    case unparseableResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未在偏好设置中配置 AI 端点 (API Key / Base URL)"
        case .badURL:
            return "模型 Base URL 格式无效"
        case .httpStatus(let code):
            return "AI 端点响应异常 (HTTP \(code))"
        case .unparseableResponse(let detail):
            return "复盘生成解析失败: \(detail)"
        }
    }
}

/// 多 Agent 账本周度智能复盘服务
final class AgentWeeklyInsightService: Sendable {
    static let shared = AgentWeeklyInsightService()

    private let session: URLSession
    private let cacheKey = "CollectionBox.lastAgentWeeklyInsight.v5"
    private static let legacyCacheKeys = [
        "CollectionBox.lastAgentWeeklyInsight",
        "CollectionBox.lastAgentWeeklyInsight.v2",
        "CollectionBox.lastAgentWeeklyInsight.v3",
        "CollectionBox.lastAgentWeeklyInsight.v4"
    ]

    init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: config)
        }
        for key in Self.legacyCacheKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 获取最近一次缓存的周度洞察
    func getCachedInsight() -> AgentWeeklyInsight? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let insight = try? JSONDecoder().decode(AgentWeeklyInsight.self, from: data) else {
            return nil
        }
        return insight
    }

    /// 清理缓存
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    /// 生成周度智能复盘洞察（支持跨模块全景工作流摘要）
    func generateInsight(
        snapshot: StatsDashboardView.DashboardSnapshot,
        workflowDigest: WorkflowObservationDigest? = nil,
        forceRefresh: Bool = false
    ) async throws -> AgentWeeklyInsight {
        if !forceRefresh, let cached = getCachedInsight() {
            if Date().timeIntervalSince(cached.createdAt) < 1800 {
                return cached
            }
        }

        let config = await MainActor.run { TodoSettingsStore.shared.config }
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw WeeklyInsightError.notConfigured
        }

        let hasCrossModule = workflowDigest?.hasCrossModuleData ?? false
        let sources = workflowDigest?.activeSourceLabels ?? ["Agent"]

        let systemPrompt: String
        if hasCrossModule {
            systemPrompt = """
            你是一个追求极致效率、语言极度凝练的硬核 macOS 开发者与工作流分析师。
            根据传入的「多 Agent 账本 + 浏览器/剪贴板/键鼠/系统使用等跨模块脱敏观测摘要」，输出一份「极简、高密度、重跨源关联归因」的周度工作流复盘报告。

            【铁律规范】
            1. 严禁任何客套、寒暄、铺垫和哲学废话；严禁把各板块数字像流水账一样简单重复！重点做跨数据源的交叉印证与归因（例如对照 Agent 吞吐高峰、键鼠输入高峰、浏览器域名构成、剪贴来源 App 与通知打扰）。
            2. 全文严格控制在 420 字以内，全部使用短点阵（bullet points），每条不超过 1~2 行。
            3. 核心数据指标（Token、时长、时段、域名/应用名、比例）一律加粗展示。

            请严格输出如下 JSON 格式：
            {
              "title": "极简复盘标题（如：周度工作流复盘 · 深夜编码心流与多端协同）",
              "summary": "一句话精辟跨源总结（串联 Agent 消耗、心流专注特征与关键瓶颈，35字以内）",
              "contentMarkdown": "极简 Markdown 正文"
            }

            Markdown 正文必须包含以下 5 个精炼章节（严格按此结构输出，不要遗漏）：

            ### ⚡️ 跨源心流与时间真相
            - **核心产出窗口**：对比 Agent 峰值时段、键鼠高峰与浏览时段，指出真正的深度心流时段与强度。
            - **碎片与打扰评估**：结合浏览域名类型（开发文档/工具 vs 资讯社交）、剪贴来源切换与系统通知打扰（如有），点明主要注意力损耗源。

            ### 🤖 Agent 账本与模型主力
            - **总量与速率**：近 7 天 **[总Token]**（命中缓存 **[命中率]**，均速 **[TPS] t/s**），领跑 Agent 为 **[Agent名称]**（**[占比]%**），主力模型 **[模型名]**。
            - **重型会话排查**：点出最重会话 `[会话标题]`（**[Token量]** / **[轮数]** 轮）并给结清建议。

            ### 🌐 信息摄取与操作节律
            - **浏览与检索重心**：概括 Dia/Chrome 总停留时长与 Top 域名构成的真实工作重心（研发检索 vs 内容消费）。
            - **剪贴与键鼠画像**：提炼高频剪贴来源 App 与键鼠输入主力应用是否与编码主线一致。

            ### 🧹 沉睡治理与损耗清理
            - **沉睡技能**：发现 **[数量]** 个连续 30 天未调用技能（点名 2~3 个），建议精简。
            - **高消耗提醒**：结合流量/通知/重型上下文指出值得收敛的后台或习惯项。

            ### 🎯 下周提效行动清单
            - 1. [动作1：基于跨源矛盾的具体时间/专注改进]
            - 2. [动作2：针对重型会话、沉睡技能或高频访问资产的收口动作]
            """
        } else {
            systemPrompt = """
            你是一个追求极致效率、语言极度凝练的硬核 macOS 开发者。
            根据传入的多 Agent 账本数据，输出一份「极简、高密度、纯干货」的周度洞察报告。

            【铁律规范】
            1. 严禁任何客套、寒暄、铺垫和哲学废话，全篇直接上数据与结论！
            2. 全文严格控制在 350 字以内，全部使用短点阵（bullet points）与数字排行，每条不超过 1~2 行。
            3. 核心数据指标（Token 数、比例、时段、名称）一律加粗展示。

            请严格输出如下 JSON 格式：
            {
              "title": "极简周报标题（如：Agent 周度战报 · 785k Tokens 与夜战心流）",
              "summary": "一句话精辟总结（包含本周总消耗、主力Agent与峰值时段，30字以内）",
              "contentMarkdown": "极简 Markdown 正文"
            }

            Markdown 正文必须严密包含以下 6 个精炼章节（严格按此结构输出，不要遗漏）：

            ### 📊 本周总消耗与黄金心流
            - **总 Token 消耗**：近 7 天共 **[总Token]** (输入 **[净输入]** / 命中缓存 **[缓存量]** / 输出 **[输出量]**)，日均 **[日均Token]**。
            - **心流黄金时段**：活跃峰值在 **[峰值时段]** (单时段吞吐 **[时段Token]**)，整机平均速率 **[TPS] t/s**，Prompt 缓存命中率 **[命中率]**。

            ### 🏆 Agent 战力排行 (消耗总额)
            - 1. **[Agent名称]**：**[Token量]** (占比 **[比例]%**)
            - 2. **[Agent名称]**：**[Token量]** (占比 **[比例]%**)
            - 3. ... (列出所有有消耗的 Agent)

            ### 🤖 模型使用排行 (Top Models)
            - 1. **[模型名]**：**[Token量]** (占比 **[比例]%**)
            - 2. **[模型名]**：**[Token量]** (占比 **[比例]%**)
            - 3. ... (列出前 3-4 个主力模型)

            ### 🛠️ 技能调用排行 (Top Skills)
            - 1. `[技能名]`：**[次数] 次** (占比 **[比例]%**)
            - 2. `[技能名]`：**[次数] 次** (占比 **[比例]%**)
            - 3. ... (列出前 4-5 个主力技能)

            ### ⚠️ 会话预警与沉睡治理
            - **最重会话**：[Agent] 的 `[会话标题]` 消耗 **[Token量]** (交互 **[轮数]** 轮)，[给出是否该结清重置的建议]。
            - **沉睡技能**：发现 **[数量]** 个连续 30 天未调用技能（如 `xxx`、`yyy`），建议清理精简提示词开销。

            ### 🎯 极客提效动作清单
            - 1. [动作1：针对最重会话或长多轮的结清建议]
            - 2. [动作2：针对沉睡技能的清理建议]
            """
        }

        let hitRatePct = String(format: "%.1f%%", snapshot.cacheHitRate)
        let tpsStr = snapshot.avgTPS.map { String(format: "%.1f", $0) } ?? "未知"
        let peakStr = snapshot.peakHour.map { String(format: "%02d:00", $0) } ?? "暂无明显单点峰值"

        // 1. 各 Agent 战力排行（按 Token 倒序排列）
        let sortedAgents = StatsAgent.allCases
            .compactMap { agent -> (agent: StatsAgent, tokens: Int)? in
                let tok = snapshot.agentTokens[agent] ?? 0
                return tok > 0 ? (agent, tok) : nil
            }
            .sorted { $0.tokens > $1.tokens }

        var agentRankText = ""
        let totalAll = snapshot.inRangeTotalTokens > 0 ? snapshot.inRangeTotalTokens : 1
        for (i, item) in sortedAgents.enumerated() {
            let share = Double(item.tokens) / Double(totalAll) * 100
            agentRankText += "\n- \(i+1). **\(item.agent.label)**: **\(WorkBuddyStats.formatTokens(item.tokens))** Tokens (占比 **\(String(format: "%.1f%%", share))**)"
        }

        // 2. 主力模型排行 (Top Models)
        var modelRankText = ""
        for (i, m) in snapshot.topModels.prefix(5).enumerated() {
            modelRankText += "\n- \(i+1). **\(m.name)**: **\(WorkBuddyStats.formatTokens(m.tokens))** (占比 **\(String(format: "%.1f%%", m.share))**)"
        }

        // 3. 王牌技能排行 (Top Skills)
        var skillRankText = ""
        for (i, s) in snapshot.skillRows.prefix(5).enumerated() {
            let agentsLabel = s.agents.map(\.label).joined(separator: "/")
            skillRankText += "\n- \(i+1). `\(s.name)`: **\(s.count) 次** (占比 **\(String(format: "%.1f%%", s.share))**, 涉及: \(agentsLabel))"
        }

        // 4. 最重长会话排查
        var topSessionsText = ""
        for (i, s) in snapshot.sessionRows.prefix(5).enumerated() {
            let tpsVal = s.tps.map { String(format: "%.1f t/s", $0) } ?? "无 TPS"
            topSessionsText += "\n- Top \(i+1): [\(s.agent.label)] \"\(s.title)\" (ID: \(s.id.prefix(8))) — 消耗 \(WorkBuddyStats.formatTokens(s.tokens)) Tokens, 交互 \(s.turns) 轮, \(tpsVal)"
        }

        // 5. 沉睡技能全量名单
        let dormantCount = snapshot.dormantSkills.count
        let dormantList = snapshot.dormantSkills.isEmpty ? "无沉睡技能" : snapshot.dormantSkills.joined(separator: ", ")

        let crossModuleText = workflowDigest?.formatForPrompt() ?? ""

        let userPrompt = """
        【本地多 Agent 真实账本切片】
        - 近 7 天总 Token 消耗：\(WorkBuddyStats.formatTokens(snapshot.d7Tokens)) Tokens
        - 近 30 天总 Token 消耗：\(WorkBuddyStats.formatTokens(snapshot.d30Tokens)) Tokens
        - 日均消耗：\(WorkBuddyStats.formatTokens(snapshot.dailyAvgTokens)) Tokens
        - 当前区间净吞吐：输入 \(WorkBuddyStats.formatTokens(snapshot.freshInput))，命中缓存 \(WorkBuddyStats.formatTokens(snapshot.cachedInput))，模型输出 \(WorkBuddyStats.formatTokens(snapshot.outputTokens))
        - Prompt Cache 总体命中率：\(hitRatePct)
        - 整机平均生成速率 (TPS)：\(tpsStr) tokens/s
        - 24 小时心流峰值黄金时段：\(peakStr) (该时段吞吐 \(WorkBuddyStats.formatTokens(snapshot.peakHourTokens)))
        - 累计会话场数：\(snapshot.allSessionsCount) 场，活跃天数：\(snapshot.activeDaysCount) 天

        【各 Agent 消耗排行与总额】
        \(agentRankText.isEmpty ? "暂无各 Agent 细分" : agentRankText)

        【总模型使用排行 (Top Models)】
        \(modelRankText.isEmpty ? "暂无模型排行" : modelRankText)

        【总 Skill 调用排行 (Top Skills)】
        - 技能总调用数：\(snapshot.totalSkillCalls) 次，当前活跃技能数：\(snapshot.activeSkillCount) 个
        \(skillRankText.isEmpty ? "暂无技能调用" : skillRankText)

        【消耗最高重型长会话 (上下文膨胀排查)】
        \(topSessionsText.isEmpty ? "暂无重型会话" : topSessionsText)

        【连续 30 天零调用沉睡技能 (共 \(dormantCount) 个)】
        \(dormantList)
        \(crossModuleText.isEmpty ? "" : "\n\(crossModuleText)")
        """

        let insight = try await sendRequest(system: systemPrompt, user: userPrompt, sources: sources, config: config)
        saveCachedInsight(insight)
        return insight
    }

    private func saveCachedInsight(_ insight: AgentWeeklyInsight) {
        if let data = try? JSONEncoder().encode(insight) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Internal HTTP & Parsing

    private func sendRequest(
        system: String,
        user: String,
        sources: [String],
        config: TodoLLMConfig
    ) async throws -> AgentWeeklyInsight {
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if trimmedBase.hasSuffix("/chat/completions") {
            urlString = trimmedBase
        } else {
            let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
            urlString = base + "/chat/completions"
        }

        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw WeeklyInsightError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WeeklyInsightError.httpStatus(http.statusCode)
        }

        return try parseResponse(data, sources: sources)
    }

    private func parseResponse(_ data: Data, sources: [String]) throws -> AgentWeeklyInsight {
        struct ChatMessage: Decodable { let content: String? }
        struct ChatChoice: Decodable { let message: ChatMessage? }
        struct ChatEnvelope: Decodable { let choices: [ChatChoice]? }

        var rawText: String?
        if let envelope = try? JSONDecoder().decode(ChatEnvelope.self, from: data),
           let content = envelope.choices?.first?.message?.content, !content.isEmpty {
            rawText = content
        } else {
            rawText = String(data: data, encoding: .utf8)
        }

        guard var text = rawText else {
            throw WeeklyInsightError.unparseableResponse("响应为空")
        }

        // 1. 去除 <think>...</think>
        if let regex = try? NSRegularExpression(pattern: "(?s)<think>.*?</think>", options: []) {
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: text.utf16.count),
                withTemplate: ""
            )
        }

        // 2. 去除 markdown 代码块
        text = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. 提取可能的 JSON 边界
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }

        struct DTO: Decodable {
            let title: String?
            let summary: String?
            let contentMarkdown: String?
        }

        guard let jsonData = text.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: jsonData) else {
            throw WeeklyInsightError.unparseableResponse(text.prefix(120).description)
        }

        return AgentWeeklyInsight(
            title: dto.title ?? "工作流周度智能复盘",
            summary: dto.summary ?? "人机心流稳定，跨模块观测已聚合。",
            contentMarkdown: dto.contentMarkdown ?? text,
            includedSources: sources
        )
    }
}
