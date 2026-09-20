import AppKit
import SwiftUI

/// Unified Preferences/Settings window for Pinner hosting SettingsView.
/// Supports tabs: General, Hotkeys, Todo AI.
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var currentTab: SettingsTab = .general

    public func show(tab: SettingsTab = .general) {
        self.currentTab = tab
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Pinner 设置"
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 580))
            w.delegate = self
            w.center()
            window = w
        }

        window?.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}
