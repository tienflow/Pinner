import Foundation

/// Pure prompt builder for fleeting thought parsing and routing.
/// Kept free of I/O so it can be cleanly unit-tested.
public enum FleetingPrompt {

    public struct Context {
        public var input: String
        public var folders: [String]
        public var recentNotes: [String]
        public var pinnedNotes: [String]
        public var folderTree: [AppleNotesService.FolderItem]
        public var lastFolder: String?
        public var lastNote: String?
        public var noteHeadSnippet: String?
        public var now: Date

        public init(
            input: String,
            folders: [String] = [],
            recentNotes: [String] = [],
            pinnedNotes: [String] = [],
            folderTree: [AppleNotesService.FolderItem] = [],
            lastFolder: String? = nil,
            lastNote: String? = nil,
            noteHeadSnippet: String? = nil,
            now: Date = Date()
        ) {
            self.input = input
            self.folders = folders
            self.recentNotes = recentNotes
            self.pinnedNotes = pinnedNotes
            self.folderTree = folderTree
            self.lastFolder = lastFolder
            self.lastNote = lastNote
            self.noteHeadSnippet = noteHeadSnippet
            self.now = now
        }
    }

    public static func build(context: Context) -> (system: String, user: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
        let nowStr = dateFormatter.string(from: context.now)

        let system = """
        你是苹果备忘录 (Apple Notes) 闪念投递智能路由器。请根据用户输入、可选分类与目标笔记，输出严格的单对象纯 JSON：
        {
          "folder": string,              // 目标文件夹分类
          "targetNoteTitle": string,      // 目标笔记标题
          "mode": "prepend"|"append"|"create", // 插入模式：置顶前插 | 尾部追加 | 新建笔记
          "formattedContent": string,     // 最终录入正文
          "confidence": number            // 0.0 ~ 1.0 置信度
        }

        核心硬约束规则：
        1. 【文本真实性铁律】：必须 100% 原样保留用户的原始文字表述！严禁任何形式的修辞润色、扩写、心理说教或自我感动。
        2. 【插入模式与格式】：
           - 若目标笔记为倒序日志/打卡类（如含“日志/打卡”）：mode 设为 "prepend"（置顶前插）。
           - 若目标笔记为日常记录、待办灵感或已有清单：mode 默认设为 "append"（尾部追加）。
           - 若用户输入为全新独立构想或无合适已有笔记承载：mode 设为 "create"（新建笔记），targetNoteTitle 提炼一个克制简明的标题（≤15字）。
           - formattedContent 必须严格基于用户原始输入，不进行任何自动天数累加或日期篡改，用户自己写了什么天数就保持什么。若未带列表符号，可规整为“- <用户原始文字>”。
        3. 【目标分类与笔记意图识别原则】：
           - 深度理解用户输入的语义核心，必须从 [备忘录分类与已有笔记] 中匹配最契合的分类与目标笔记。
           - 语义路由参考：
             * 读书名句、体验感悟、人生金句、生活闲思随笔 → 优先归入《妙笔偶得》或《有感而发》；
             * 情绪反思、亲密关系复盘、戒断与认知重塑、日常打卡/天数记录 → 优先归入《清醒备忘》对应笔记（如【断联日志】、【认知重塑】等）；
             * 知识点、速查表、打印、驾驶技巧、模型方法 → 优先归入《日积月累》；
             * 生活开销、资产健康、个人资料档案 → 优先归入《生活台账》；
             * 房屋装修、尺寸家具、电路设计 → 优先归入《装修笔记》。
           - 若用户输入是对已有某个笔记的记录或补充，直接选择该已有笔记（mode 设为 "append" 或倒序日志的 "prepend"）；
           - 只有当输入为全新的独立专题且无合适已有笔记承载时，才选择最贴切的文件夹并新建笔记（mode: "create"，简炼标题 ≤15 字）。
           - 严禁盲目默认偏向某一特定笔记，每次识别必须完全基于用户当前输入的真实语义！
        4. 只输出纯 JSON 字符串，严禁任何思考标记（如 <think>）、前后解释、Markdown 代码块标记（```json）。
        """

        var user = "[当前时间: \(nowStr)]\n"
        if !context.folderTree.isEmpty {
            user += "[备忘录分类与已有笔记]:\n"
            for item in context.folderTree {
                if item.notes.isEmpty {
                    user += "- \(item.name): (暂无笔记)\n"
                } else {
                    let preview = item.notes.prefix(35).joined(separator: ", ")
                    user += "- \(item.name): [\(preview)]\n"
                }
            }
        } else {
            if !context.folders.isEmpty {
                user += "[可用文件夹: \(context.folders.joined(separator: ", "))]\n"
            }
            if !context.recentNotes.isEmpty {
                user += "[最近笔记列表: \(context.recentNotes.prefix(30).joined(separator: ", "))]\n"
            }
        }
        if !context.pinnedNotes.isEmpty {
            user += "[常用常驻笔记: \(context.pinnedNotes.joined(separator: ", "))]\n"
        }
        user += "用户输入: \(context.input)"

        return (system, user)
    }
}
