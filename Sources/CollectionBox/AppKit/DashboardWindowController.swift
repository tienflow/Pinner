import AppKit
import SwiftUI

/// Regular (non-panel) dashboard window opened from the "总览" menu
/// item. One shared instance; size/position persist via frame autosave.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window != nil }

    func show() {
        if window == nil {
            // AgentKeyWindow keeps menu shortcuts (⌘C/⌘V/⌘W/⌘Q) alive while the
            // app stays `.accessory`, i.e. without a Dock icon.
            let w = AgentKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "统计总览"
            w.titlebarAppearsTransparent = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PinnerDashboardWindow")
            w.contentView = NSHostingView(rootView: StatsDashboardView())
            w.delegate = self
            w.center()
            window = w
        }
        AppActivationManager.updateActivationPolicy()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // contentView holds @State; releasing the hosting view resets state so
        // the next open starts a fresh scan.
        window?.contentView = nil
        window = nil
        AppActivationManager.updateActivationPolicy()
    }
}
