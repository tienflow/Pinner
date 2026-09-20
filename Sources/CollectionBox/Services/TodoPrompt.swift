import Foundation

/// Pure prompt builder for the todo parser.
/// Kept free of I/O so it can be unit-tested by PinnerTestRunner.
enum TodoPrompt {

    /// Build the system + user prompt pair for a natural-language todo input.
    static func build(input: String, now: Date = Date(), lists: [String], lastList: String?) -> (system: String, user: String) {
        let iso = Self.isoFormatter.string(from: now)
        let weekday = Self.weekdayFormatter.string(from: now)

        let system = """
        你是待办解析器。输出结构化 JSON：
          {"title": str, "due": ISO8601|null, "priority": 0|1|5|9, "list": str|null, "fallback": bool}
          规则：
          - title 提取核心任务动作与内容，剔除时间词、优先级词（如重要/加急/低优）及列表指定词
          - due 输出带时区偏移的本地时间 ISO8601（如 2026-09-18T15:00:00+08:00），禁止裸 UTC；无法确定到期日时填 null 且 fallback=true
          - priority 识别或推断优先级：
            * 1（高）：含「重要/紧急/加急/优先/尽快/抓紧/必须/第一/P0/P1/高优」或紧迫期限
            * 5（中）：含「一般/普通/正常/中等/P2」
            * 9（低）：含「随便/不急/有空/延后/低优/P3」
            * 0（无）：未体现特殊优先级
          - list 所属列表推断与匹配：
            * 若原文显式点名列表（如「放到工作里」→ "工作"），精准匹配
            * 若原文未显式点名但存在[可选列表]，请根据待办语义智能归类至最契合的可选列表名（如工作任务/邮件/周报归类到工作，买菜/日用品归类到采购/购物，生活起居归类到日常）
            * 若无法契合任何可选列表，填 null
          - fallback=true 表示无法可靠解析，用于区分「无法解析」与「原文无时间词」
          - 只输出单个纯 JSON 对象，严禁任何思考过程、前后解释说明或代码块标记
        """

        var user = "[参考时间: \(iso) 周\(weekday)]\n"
        if !lists.isEmpty {
            user += "[可选列表: \(lists.joined(separator: ", "))]\n"
        }
        if let lastList, !lastList.isEmpty {
            user += "[上次选择的列表: \(lastList)]\n"
        }
        user += "输入: \(input)"

        return (system, user)
    }

    // MARK: - Formatters

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()
}