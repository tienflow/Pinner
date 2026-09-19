import AppKit
import UserNotifications

/// Posts a system notification when a global hotkey could not be registered
/// (combo taken by the system or another app). Fire-and-forget.
enum HotkeyRegistrationNotifier {
    private static let center: UNUserNotificationCenter? = {
        // CLI test runners have no bundle; guard instead of crashing.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    static func notifyFailure(label: String? = nil, combo: HotkeyCombo) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "快捷键注册失败"
            content.body = "「\(combo.displayString)」\(label.map { "（\($0)）" } ?? "")可能已被其他应用或系统占用，请到 设置 中换一个组合键。"
            let request = UNNotificationRequest(identifier: "hotkey-fail-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }
}
