import Foundation
import Combine

/// Mental model clusters for grouping Pinner capabilities.
public enum ModuleCluster: String, CaseIterable, Sendable {
    case capture = "录入"
    case observation = "观测"
    case tools = "工具"

    public var subtitle: String {
        switch self {
        case .capture:
            return "任务与灵感的快捷录入工作流"
        case .observation:
            return "AI 编程开销与键鼠输入的只读统计"
        case .tools:
            return "本地系统检视与快捷操作工具"
        }
    }

    public var icon: String {
        switch self {
        case .capture:
            return "square.and.pencil"
        case .observation:
            return "chart.xyaxis.line"
        case .tools:
            return "wrench.and.screwdriver"
        }
    }
}

/// Distinct feature modules that can be selectively toggled in Settings.
public enum PinnerModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case collection = "collection"
    case todo = "todo"
    case fleeting = "fleeting"
    case agentStats = "agentStats"
    case inputStats = "inputStats"
    case portManager = "portManager"
    case processManager = "processManager"
    case otp = "otp"

    public var id: String { rawValue }

    /// Single naming source for both the status-bar menu and the settings
    /// pane. Keeping two titles in sync by hand is how drift starts.
    public var title: String {
        switch self {
        case .collection: return "收藏夹"
        case .todo: return "待办"
        case .fleeting: return "闪念"
        case .otp: return "验证码"
        case .agentStats: return "Agent 总览"
        case .inputStats: return "键鼠统计"
        case .portManager: return "端口"
        case .processManager: return "进程"
        }
    }

    public var subtitle: String {
        switch self {
        case .collection:
            return "屏幕边缘吸附抽屉、书签分类管理与临时文件暂存架（核心基础功能）"
        case .todo:
            return "快捷键调出智能录入框，由大模型理解自然语言并沉淀至系统提醒事项"
        case .fleeting:
            return "随时随地捕捉灵感与碎碎念，流式规整并自动追加到 Apple 备忘录"
        case .otp:
            return "本地加密存储两步验证密钥，快捷计算并自动复制 6 位动态验证码"
        case .agentStats:
            return "跨 IDE 汇总 Codex、Antigravity、WorkBuddy 等各 Agent 的消耗与节律"
        case .inputStats:
            return "全局按键、鼠标点击、滚轮与移动距离统计，支持心流节律分析"
        case .portManager:
            return "监控本地监听端口与开发服务，支持进程详情穿透与一键释放"
        case .processManager:
            return "系统负载诊断、统一内存压力与高耗卡死进程排查与一键处置"
        }
    }

    public var icon: String {
        switch self {
        case .collection: return "tray.full"
        case .todo: return "checklist"
        case .fleeting: return "note.text.badge.plus"
        case .otp: return "lock.shield"
        case .agentStats: return "chart.bar.xaxis"
        case .inputStats: return "keyboard"
        case .portManager: return "network"
        case .processManager: return "speedometer"
        }
    }

    /// The collection drawer is the heart of Pinner and cannot be disabled.
    public var isCore: Bool {
        self == .collection
    }

    public var cluster: ModuleCluster {
        switch self {
        case .collection, .todo, .fleeting:
            return .capture
        case .agentStats, .inputStats:
            return .observation
        case .portManager, .processManager, .otp:
            return .tools
        }
    }
}

/// Central manager for modular features and persistence.
public final class ModuleManager: ObservableObject {
    public static let shared = ModuleManager()
    private static let defaultsKey = "Pinner.enabledModules"
    private let defaults: UserDefaults

    @Published public private(set) var enabledModules: Set<PinnerModule> {
        didSet {
            let keys = enabledModules.map(\.rawValue).sorted()
            defaults.set(keys, forKey: Self.defaultsKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.defaultsKey) {
            var decoded = Set(saved.compactMap(PinnerModule.init(rawValue:)))
            // Core module is always active
            decoded.insert(.collection)
            // Ensure newly introduced modules like portManager default to enabled
            let migrationKey = "Pinner.initializedModules"
            var initialized = Set(defaults.stringArray(forKey: migrationKey) ?? [])
            for module in PinnerModule.allCases {
                if !initialized.contains(module.rawValue) {
                    decoded.insert(module)
                    initialized.insert(module.rawValue)
                }
            }
            defaults.set(Array(initialized), forKey: migrationKey)
            self.enabledModules = decoded
        } else {
            self.enabledModules = Set(PinnerModule.allCases)
            defaults.set(PinnerModule.allCases.map(\.rawValue), forKey: "Pinner.initializedModules")
        }
    }

    public func isEnabled(_ module: PinnerModule) -> Bool {
        if module.isCore { return true }
        return enabledModules.contains(module)
    }

    public func setEnabled(_ module: PinnerModule, to on: Bool) {
        if module.isCore { return } // Cannot disable core
        if on {
            enabledModules.insert(module)
            if module == .inputStats {
                Task { @MainActor in
                    InputStatsService.shared.startMonitoring()
                }
            }
        } else {
            enabledModules.remove(module)
            if module == .inputStats {
                Task { @MainActor in
                    InputStatsService.shared.stopMonitoring()
                }
            } else if module == .portManager {
                Task { @MainActor in
                    PortManagerWindowController.shared.hide()
                }
            }
        }
    }
}
