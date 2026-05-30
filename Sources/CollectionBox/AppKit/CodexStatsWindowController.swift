import AppKit
import SwiftUI

private final class StatsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CodexStatsWindowController: NSObject {
    private var panel: NSPanel?
    private(set) var isShowing = false
    private var mouseMonitor: Any?

    func toggle() {
        if isShowing { hide() } else { showAtMouse() }
    }

    func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 360, h: CGFloat = 320
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    func showAtMouse() {
        if isShowing { hide(); return }

        let w: CGFloat = 360, h: CGFloat = 320
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let x: CGFloat
        if mouse.x < screen.frame.midX { x = mouse.x + 4 } else { x = mouse.x - w - 4 }
        let y: CGFloat
        if mouse.y - h < screen.frame.minY { y = screen.frame.minY + 4 }
        else if mouse.y > screen.frame.maxY - h / 2 { y = screen.frame.maxY - h - 4 }
        else { y = mouse.y - h / 2 }
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    private func showPanel(in frame: NSRect) {
        let p = StatsKeyPanel(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = true
        p.backgroundColor = .windowBackgroundColor
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.isReleasedWhenClosed = false

        let hv = NSHostingView(rootView: CodexStatsView())
        hv.frame = p.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
        self.isShowing = true

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
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
}

extension CodexStatsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        isShowing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.isShowing else { return }
            if NSApp.keyWindow == nil { self.hide() }
        }
    }
}
