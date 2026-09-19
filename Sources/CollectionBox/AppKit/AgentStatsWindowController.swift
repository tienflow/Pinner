import AppKit
import SwiftUI

private final class AgentStatsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Compact stats panel for an agent, mirroring WorkBuddyStatsWindowController.
final class AgentStatsWindowController: NSObject {
    private let agent: StatsAgent
    private var panel: NSPanel?
    private(set) var isShowing = false
    private var mouseMonitor: Any?

    init(agent: StatsAgent) {
        self.agent = agent
        super.init()
    }

    func toggle() {
        if isShowing { hide() } else { showAtMouse() }
    }

    func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 360, h: CGFloat = 336
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
        // Autosave restores the remembered size after positioning; keep the
        // panel top edge pinned under the menu bar icon.
        if let p = panel {
            var f = p.frame
            f.origin.x = min(f.origin.x, buttonFrame.maxX - f.width)
            f.origin.y = buttonFrame.origin.y - f.height - 2
            p.setFrame(f, display: true)
        }
    }

    func showAtMouse() {
        if isShowing { hide(); return }

        let w: CGFloat = 360, h: CGFloat = 336
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
        let p = AgentStatsKeyPanel(contentRect: frame,
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
        // Remember user-resized size; anchor stays at the menu bar / cursor.
        p.setFrameAutosaveName("PinnerAgentStatsPanel.\(agent.rawValue)")

        let hv = NSHostingView(rootView: AgentStatsView(agent: agent))
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

extension AgentStatsWindowController: NSWindowDelegate {
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
