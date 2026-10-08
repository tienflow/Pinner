import AppKit
import SwiftUI

/// Unified Preferences/Settings window for Pinner hosting SettingsView.
/// Supports tabs: General, Hotkeys, Todo AI.
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var currentTab: SettingsTab = .general

    public var isVisible: Bool { window != nil }

    public func show(tab: SettingsTab = .general) {
        self.currentTab = tab
        if window == nil {
            // AgentKeyWindow keeps menu shortcuts (⌘C/⌘V/⌘W/⌘Q) alive while the
            // app stays `.accessory`, i.e. without a Dock icon.
            // The tab content is a ScrollView that grows with custom hotkey rows, so the
            // window must stay user-resizable — a fixed 560x600 frame forces
            // scrolling even on a large display.
            let w = AgentKeyWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Pinner 设置"
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 600))
            w.delegate = self
            w.center()
            window = w
        }

        window?.contentView = NSHostingView(rootView: SettingsView(initialTab: tab))
        AppActivationManager.updateActivationPolicy()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        AppActivationManager.updateActivationPolicy()
    }
}
