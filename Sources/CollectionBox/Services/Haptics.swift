import AppKit

/// macOS Force Touch 触控板震动触感反馈服务。
/// 在具备 Force Touch 触控板的 Mac 上产生原生触感反馈，外接普通鼠标或不支持设备上静默忽略。
public enum Haptics {
    /// 触发原生触感反馈
    public static func play(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .generic,
                            performanceTime: NSHapticFeedbackManager.PerformanceTime = .default) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: performanceTime)
    }

    /// 标记完成 / 复制成功 / 保存成功（清脆对齐咔哒感）
    public static func success() {
        play(.alignment)
    }

    /// 轻量点击 / 打开项目 / 选中微反馈
    public static func light() {
        play(.generic)
    }

    /// 删除 / 状态切换 / 拖出即焚物理销毁（明确的级别切换反馈）
    public static func levelChange() {
        play(.levelChange)
    }
}
