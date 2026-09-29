import AppKit
import SwiftUI

private final class FleetingCaptureKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Floating panel controller for fleeting thoughts capture → Apple Notes.
/// Lightweight, floating, auto-centered or mouse-adjacent, rebuilt on open.
public final class FleetingCaptureWindowController: NSObject, NSWindowDelegate {
    public static let shared = FleetingCaptureWindowController()

    private var panel: NSPanel?
    public private(set) var isShowing = false
    private var mouseMonitor: Any?

    private static var hasRecentTargets: Bool {
        if let data = UserDefaults.standard.data(forKey: "CollectionBox.fleetingRecentTargets"),
           let list = try? JSONDecoder().decode([RecentTarget].self, from: data) {
            return !list.isEmpty
        }
        return false
    }

    public func toggle() {
        if isShowing { hide() } else { showAtMouse() }
    }

    public static func initialHeight() -> CGFloat {
        hasRecentTargets ? 254 : 216
    }

    public func showAtMouse() {
        if isShowing { hide(); return }

        let w: CGFloat = 440, h: CGFloat = Self.initialHeight()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]

        // Center on screen or near mouse
        let x = screen.frame.midX - w / 2
        let y = screen.frame.midY - h / 2 + 50
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    public func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 440, h: CGFloat = Self.initialHeight()
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 4
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    public func updateHeight(isExpanded: Bool, isParsing: Bool, hasStatus: Bool = false, animated: Bool = true) {
        guard let p = panel else { return }
        let hasRecents = Self.hasRecentTargets
        var targetH: CGFloat
        if isExpanded {
            targetH = hasRecents ? 510 : 472
        } else if isParsing {
            targetH = hasRecents ? 300 : 262
        } else {
            targetH = hasRecents ? 254 : 216
        }

        if hasStatus {
            targetH += 34
        }

        if abs(p.frame.height - targetH) > 2 {
            var frame = p.frame
            let diff = targetH - frame.height
            frame.origin.y -= diff
            frame.size.height = targetH

            if let screen = p.screen ?? NSScreen.main {
                if frame.origin.y < screen.visibleFrame.minY + 10 {
                    frame.origin.y = screen.visibleFrame.minY + 10
                }
            }

            p.setFrame(frame, display: true, animate: animated)
        }
    }

    private func showPanel(in frame: NSRect) {
        let p = FleetingCaptureKeyPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.isReleasedWhenClosed = false

        let captureView = FleetingCaptureView { [weak self] in
            self?.hide()
        }

        let hv = NSHostingView(rootView: captureView)
        hv.frame = p.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
        self.isShowing = true

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let p = self.panel else { return }
            if !NSMouseInRect(NSEvent.mouseLocation, p.frame, false) {
                self.hide()
            }
        }
    }

    public func hide() {
        guard isShowing else { return }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    public func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        isShowing = false
    }
}
