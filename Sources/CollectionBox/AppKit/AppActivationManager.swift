import AppKit

/// Pinner is a menu-bar-only app (`LSUIElement` + `.accessory`), so it never
/// shows a Dock icon. Regular windows (总览 / 偏好设置) stay fully usable under
/// `.accessory` — they can become key and take keyboard focus — but macOS hides
/// the app menu bar in that mode, and the menu bar is where ⌘C / ⌘V / ⌘W / ⌘Q
/// normally come from. `EscDismissableWindow` restores those by handing key
/// equivalents to the main menu explicitly.
///
/// This used to flip the app to `.regular` while a regular window was visible,
/// which is exactly what made a Pinner icon pop up in the Dock.
public enum AppActivationManager {
    /// Keeps the app in `.accessory`. Call it before showing/hiding a regular
    /// window to recover from any state that set a different policy.
    public static func updateActivationPolicy() {
        let block = {
            if NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
