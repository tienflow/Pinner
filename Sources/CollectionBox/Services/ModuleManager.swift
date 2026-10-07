import Foundation
import Combine

/// Mental model clusters for grouping Pinner capabilities.
public enum ModuleCluster: String, CaseIterable, Sendable {
    case captureAndWorkspace = "工作台与捕获"
    case monitoringAndTools = "数字监控与工具"

    public var subtitle: String {
        switch self {
        case .captureAndWorkspace:
            return "文件收纳、碎片灵感与任务录入工作流"
        case .monitoringAndTools:
            return "AI 编程开销监控、硬件键鼠节律与效率工具"
        }
    }

    public var icon: String {
        switch self {
        case .captureAndWorkspace:
            return "tray.2.fill"
        case .monitoringAndTools:
            return "chart.xyaxis.line"
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
    case otp = "otp"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .collection: return "收藏夹与暂存架"
        case .todo: return "智能待办"
        case .fleeting: return "闪念笔记"
        case .agentStats: return "AI Token 统计看板"
        case .inputStats: return "键鼠输入统计"
        case .portManager: return "端口管家"
        case .otp: return "OTP 两步验证码"
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
        case .agentStats:
            return "跨 IDE 汇总 Codex、Antigravity、WorkBuddy 等各 Agent 的消耗与节律"
        case .inputStats:
            return "全局按键、鼠标点击、滚轮与移动距离统计，支持心流节律分析"
        case .portManager:
            return "监控本地监听端口与开发服务，支持进程详情穿透与一键释放"
        case .otp:
            return "本地加密存储两步验证密钥，快捷计算并自动复制 6 位动态验证码"
        }
    }

    public var icon: String {
        switch self {
        case .collection: return "tray.full"
        case .todo: return "checklist"
        case .fleeting: return "note.text.badge.plus"
        case .agentStats: return "chart.bar.xaxis"
        case .inputStats: return "keyboard"
        case .portManager: return "network"
        case .otp: return "lock.shield"
        }
    }

    /// The collection drawer is the heart of Pinner and cannot be disabled.
    public var isCore: Bool {
        self == .collection
    }

    public var cluster: ModuleCluster {
        switch self {
        case .collection, .todo, .fleeting:
            return .captureAndWorkspace
        case .agentStats, .inputStats, .portManager, .otp:
            return .monitoringAndTools
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
