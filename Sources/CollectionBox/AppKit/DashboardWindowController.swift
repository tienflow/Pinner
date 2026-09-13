import AppKit
import SwiftUI

/// Regular (non-panel) dashboard window opened from the "Pinner 设置" menu
/// item. One shared instance; size/position persist via frame autosave.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Pinner 设置"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PinnerDashboardWindow")
            w.contentView = NSHostingView(rootView: StatsDashboardView())
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // contentView holds @State; releasing the hosting view resets state so
        // the next open starts a fresh scan.
        window?.contentView = nil
        window = nil
    }
}
