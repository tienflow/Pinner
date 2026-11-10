import AppKit
import SwiftUI

/// Specialized window for the Agent Dashboard.
/// - Inherits EscDismissableWindow to support Esc key handling.
/// - Automatically resigns focus (first responder) when clicking on empty background or non-text areas.
final class DashboardWindow: EscDismissableWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if let responder = self.firstResponder as? NSView {
                let location = event.locationInWindow
                if let fieldEditor = responder as? NSTextView {
                    let targetView = (fieldEditor.delegate as? NSView) ?? fieldEditor
                    let targetRect = targetView.convert(targetView.bounds, to: nil)
                    let hitRect = targetRect.insetBy(dx: -28, dy: -8)
                    if !hitRect.contains(location) {
                        self.makeFirstResponder(nil)
                    }
                } else if responder is NSTextField {
                    let targetRect = responder.convert(responder.bounds, to: nil)
                    let hitRect = targetRect.insetBy(dx: -28, dy: -8)
                    if !hitRect.contains(location) {
                        self.makeFirstResponder(nil)
                    }
                }
            }
        }
        super.sendEvent(event)
    }
}

/// Regular (non-panel) dashboard window opened from the "总览" menu
/// item. One shared instance; size/position persist via frame autosave.
final class DashboardWindowController: NSObject, NSWindowDelegate {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            // DashboardWindow forwards key equivalents to the main menu so
            // ⌘C/⌘V/⌘W/⌘Q stay alive while the app stays `.accessory`
            // (no Dock icon, no menu bar).
            let w = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Agent 总览"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 1080, height: 680)
            w.contentView = NSHostingView(rootView: StatsDashboardView())
            w.initialFirstResponder = w.contentView
            w.setContentSize(NSSize(width: 1180, height: 780))
            w.center()
            w.setFrameAutosaveName("PinnerDashboardWindow")
            if w.frame.width < 1140 || w.frame.height < 740 {
                w.setContentSize(NSSize(width: 1180, height: 780))
                w.center()
            }
            w.delegate = self
            window = w
        }
        AppActivationManager.updateActivationPolicy()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: NSNotification.Name("PinnerDashboardDidShow"), object: nil)
    }

    func close() {
        window?.orderOut(nil)
        AppActivationManager.updateActivationPolicy()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        AppActivationManager.updateActivationPolicy()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        AppActivationManager.updateActivationPolicy()
    }
}
