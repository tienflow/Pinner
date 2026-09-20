import AppKit
import SwiftUI

/// Settings window for the todo LLM: Base URL / API Key / model + test button.
/// Regular (non-panel) window so it can host a secure text field comfortably.
final class TodoSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = TodoSettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "待办 AI 设置"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PinnerTodoSettingsWindow")
            w.contentView = NSHostingView(rootView: TodoSettingsView())
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}