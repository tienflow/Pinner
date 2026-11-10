import Foundation

enum DiagnosticStatusLevel: String, Codable, Sendable {
    case healthy = "健康"
    case warning = "轻微受压"
    case critical = "严重受压"

    var colorName: String {
        switch self {
        case .healthy: return "green"
        case .warning: return "orange"
        case .critical: return "red"
        }
    }

    var iconName: String {
        switch self {
        case .healthy: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "flame.fill"
        }
    }
}

enum DiagnosticActionType: String, Codable, Sendable {
    case none = "无需处置"
    case suspend = "建议挂起"
    case terminate = "建议强杀"
}

struct SystemDiagnosticReport: Identifiable, Sendable {
    let id = UUID()
    let statusLevel: DiagnosticStatusLevel
    let summary: String
    let primaryCulprit: String?
    let targetPID: pid_t?
    let suggestedAction: DiagnosticActionType
    let findings: [String]
    let recommendations: [String]
    let createdAt: Date

    init(
        statusLevel: DiagnosticStatusLevel,
        summary: String,
        primaryCulprit: String? = nil,
        targetPID: pid_t? = nil,
        suggestedAction: DiagnosticActionType = .none,
        findings: [String] = [],
        recommendations: [String] = [],
        createdAt: Date = Date()
    ) {
        self.statusLevel = statusLevel
        self.summary = summary
        self.primaryCulprit = primaryCulprit
        self.targetPID = targetPID
        self.suggestedAction = suggestedAction
        self.findings = findings
        self.recommendations = recommendations
        self.createdAt = createdAt
    }
}

enum ProcessDoctorError: LocalizedError {
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
            return "AI 诊断解析失败: \(detail)"
        }
    }
}

/// 进程与系统卡顿诊断服务
final class AIProcessDoctorService: Sendable {
    static let shared = AIProcessDoctorService()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let s = session {
            self.session = s
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
    }

    /// 执行整机系统卡顿与资源压力诊断
    func diagnoseSystem(
        pressure: SystemPressureInfo,
        topProcesses: [ManagedProcessEntry]
    ) async throws -> SystemDiagnosticReport {
        let config = await MainActor.run { TodoSettingsStore.shared.config }
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw ProcessDoctorError.notConfigured
        }

        let listeningMap = await resolveListeningPortsByPID()

        let systemPrompt = """
        你是一个精通 macOS (Darwin/Mach 内核) 架构的顶级系统性能调优与故障排查专家。
        你的任务是根据传入的 macOS 实时性能快照（CPU负载、统一内存压力、Swap换页、Top活跃进程、命令行参数与监听端口），诊断系统当前卡顿或发热的根本原因，并给出果断干脆的处置建议。
        注意：若进程带有 [监听端口: :xxxx] 标记，说明它正在承载活跃的本地开发服务、容器或网络监听（如 node/python/vite 等），除非确认死循环或失控，否则切勿将其误判为无用闲置进程而盲目建议强杀。

        请严格输出如下 JSON 格式，不要包含任何额外的文本或解释：
        {
          "statusLevel": "healthy" | "warning" | "critical",
          "summary": "一句话核心归因与定性（40字以内）",
          "primaryCulprit": "最核心元凶进程名（若无则为 null）",
          "targetPID": 1234, // 元凶 PID（数字，若无则为 null）
          "suggestedAction": "none" | "suspend" | "terminate",
          "findings": [
            "事实发现1",
            "事实发现2"
          ],
          "recommendations": [
            "排查与处置建议1",
            "排查与处置建议2"
          ]
        }
        """

        let cpuUser = Int(pressure.cpuUserPercent)
        let cpuSys = Int(pressure.cpuSystemPercent)
        let cpuTotal = String(format: "%.1f", pressure.cpuTotalPercent)
        let memPressure = pressure.memoryPressure.rawValue
        let memUsedGB = Double(pressure.physicalMemoryUsedBytes) / 1_073_741_824.0
        let memTotalGB = Double(pressure.physicalMemoryTotalBytes) / 1_073_741_824.0
        let swapMB = Double(pressure.swapUsedBytes) / 1_048_576.0

        var procsText = ""
        for (i, p) in topProcesses.prefix(8).enumerated() {
            let args = p.arguments.map { " (参数: \($0))" } ?? ""
            let status = p.isSuspended ? "[已挂起]" : ""
            let ports = listeningMap[p.pid] ?? []
            let portsTag = ports.isEmpty ? "" : " [监听端口: \(ports.map { ":\($0)" }.joined(separator: ", "))]"
            procsText += "\n\(i+1). PID:\(p.pid) | \(p.name)\(status)\(portsTag) | CPU:\(p.cpuDisplayString) | 内存:\(p.memoryDisplayString) | 功耗:\(p.energyDisplayString)\(args)"
        }

        let userPrompt = """
        【当前系统快照】
        - 硬件：\(pressure.logicalCores) 核 CPU
        - CPU 综合负载：\(cpuTotal)% (用户态: \(cpuUser)%, 系统内核: \(cpuSys)%)
        - 统一内存：\(String(format: "%.1f", memUsedGB)) GB / \(String(format: "%.0f", memTotalGB)) GB (压力等级: \(memPressure))
        - Swap 磁盘交换：\(String(format: "%.0f", swapMB)) MB
        - 资源占用最高进程清单：\(procsText.isEmpty ? "暂无高负载进程" : procsText)
        """

        return try await sendRequest(system: systemPrompt, user: userPrompt, config: config)
    }

    /// 针对单个具体进程进行深入异常诊断
    func diagnoseProcess(
        process: ManagedProcessEntry,
        systemPressure: SystemPressureInfo
    ) async throws -> SystemDiagnosticReport {
        let config = await MainActor.run { TodoSettingsStore.shared.config }
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw ProcessDoctorError.notConfigured
        }

        let listeningMap = await resolveListeningPortsByPID()
        let ports = listeningMap[process.pid] ?? []
        let portsDesc = ports.isEmpty ? "无" : "[监听端口: \(ports.map { ":\($0)" }.joined(separator: ", "))]"

        let systemPrompt = """
        你是一个精通 macOS 进程诊断的专家。
        根据给定的进程详情（PID、名称、参数、监听端口、资源占用）和全局系统背景，诊断该进程是否存在死循环、内存泄露、高频 I/O 挂起或不合理的资源占用。
        注意：若该进程带有 [监听端口: :xxxx]，表明它正在提供本地开发服务或网络监听（如 node、python、数据库或代理服务），请结合其服务属性客观评估，避免误判为闲置残留进程。

        请严格输出如下 JSON 格式：
        {
          "statusLevel": "healthy" | "warning" | "critical",
          "summary": "一句话核心诊断（40字以内）",
          "primaryCulprit": "\(process.name)",
          "targetPID": \(process.pid),
          "suggestedAction": "none" | "suspend" | "terminate",
          "findings": [
            "事实发现1",
            "事实发现2"
          ],
          "recommendations": [
            "建议1",
            "建议2"
          ]
        }
        """

        let userPrompt = """
        【目标进程分析】
        - PID: \(process.pid)
        - 进程名称: \(process.name)
        - 显示名称: \(process.displayName)
        - 完整路径: \(process.fullPath)
        - 命令行参数: \(process.arguments ?? "无")
        - 端口监听状态: \(portsDesc)
        - 当前 CPU: \(process.cpuDisplayString)
        - 驻留内存: \(process.memoryDisplayString)
        - 瞬时功耗影响: \(process.energyDisplayString)
        - 状态: \(process.isSuspended ? "已被暂停 (SIGSTOP)" : "运行中")
        - 分类: \(process.category.rawValue)

        【整机背景】
        - CPU 综合负载: \(String(format: "%.1f%%", systemPressure.cpuTotalPercent))
        - 内存压力: \(systemPressure.memoryPressure.rawValue)
        - Swap 磁盘交换: \(systemPressure.swapDisplayString)
        """

        return try await sendRequest(system: systemPrompt, user: userPrompt, config: config)
    }

    /// 结合 PortManagerService 缓存与快速 lsof 扫描，提取 PID 对应的本地监听端口列表
    private func resolveListeningPortsByPID() async -> [pid_t: [Int]] {
        let cachedProcs = await MainActor.run { PortManagerService.shared.processes }
        var map: [pid_t: Set<Int>] = [:]
        for proc in cachedProcs {
            for port in proc.ports {
                map[proc.pid, default: []].insert(port)
            }
        }
        let scanned = await Task.detached(priority: .utility) {
            Self.quickScanListeningPortsByPID()
        }.value
        for (pid, ports) in scanned {
            map[pid, default: []].formUnion(ports)
        }
        var sortedMap: [pid_t: [Int]] = [:]
        for (pid, ports) in map {
            sortedMap[pid] = ports.sorted()
        }
        return sortedMap
    }

    private nonisolated static func quickScanListeningPortsByPID() -> [pid_t: Set<Int>] {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-n", "-P", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [pid_t: Set<Int>] = [:]
        var currentPid: pid_t? = nil
        output.enumerateLines { line, _ in
            guard let first = line.first else { return }
            let val = String(line.dropFirst())
            if first == "p", let pid = pid_t(val) {
                currentPid = pid
            } else if first == "n", let pid = currentPid, let colonIdx = val.lastIndex(of: ":") {
                let portStr = String(val[val.index(after: colonIdx)...])
                if let port = Int(portStr) {
                    result[pid, default: []].insert(port)
                }
            }
        }
        return result
    }

    // MARK: - Internal HTTP & Parsing

    private func sendRequest(
        system: String,
        user: String,
        config: TodoLLMConfig
    ) async throws -> SystemDiagnosticReport {
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString: String
        if trimmedBase.hasSuffix("/chat/completions") {
            urlString = trimmedBase
        } else {
            let base = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
            urlString = base + "/chat/completions"
        }

        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw ProcessDoctorError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.1,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProcessDoctorError.httpStatus(http.statusCode)
        }

        return try parseResponse(data)
    }

    private func parseResponse(_ data: Data) throws -> SystemDiagnosticReport {
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
            throw ProcessDoctorError.unparseableResponse("响应体为空")
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
            let statusLevel: String?
            let summary: String?
            let primaryCulprit: String?
            let targetPID: Int?
            let suggestedAction: String?
            let findings: [String]?
            let recommendations: [String]?
        }

        guard let jsonData = text.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: jsonData) else {
            throw ProcessDoctorError.unparseableResponse(text.prefix(120).description)
        }

        let level: DiagnosticStatusLevel
        switch dto.statusLevel?.lowercased() {
        case "critical", "严重", "告警": level = .critical
        case "warning", "受压", "亚健康": level = .warning
        default: level = .healthy
        }

        let action: DiagnosticActionType
        switch dto.suggestedAction?.lowercased() {
        case "suspend", "暂停", "挂起": action = .suspend
        case "terminate", "kill", "强杀", "终止": action = .terminate
        default: action = .none
        }

        return SystemDiagnosticReport(
            statusLevel: level,
            summary: dto.summary ?? "系统整体运行平稳",
            primaryCulprit: dto.primaryCulprit,
            targetPID: dto.targetPID.map { pid_t($0) },
            suggestedAction: action,
            findings: dto.findings ?? [],
            recommendations: dto.recommendations ?? []
        )
    }
}
