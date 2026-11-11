import AppKit
import SwiftUI

/// Frame height that fits the title bar, range picker, metric cards, breakdown
/// capsule, trend chart and bottom bar.
private let agentPanelHeight: CGFloat = 380

/// Compact floating stats panel parameterized by `StatsAgent`.
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

        let w: CGFloat = 360, h: CGFloat = agentPanelHeight
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

        let w: CGFloat = 360, h: CGFloat = agentPanelHeight
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
        // Autosave may restore a height other than the one used to centre the
        // panel on the cursor; re-centre and re-clamp to the screen.
        if let p = panel, p.frame.height != h {
            var f = p.frame
            f.origin.y = mouse.y - f.height / 2
            if f.origin.y < screen.frame.minY { f.origin.y = screen.frame.minY + 4 }
            else if f.origin.y + f.height > screen.frame.maxY { f.origin.y = screen.frame.maxY - f.height - 4 }
            p.setFrame(f, display: true)
        }
    }

    private func showPanel(in frame: NSRect) {
        let p = EscDismissablePanel(contentRect: frame,
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.isReleasedWhenClosed = false
        // Remember user-resized size; anchor stays at the menu bar / cursor.
        p.setFrameAutosaveName("PinnerAgentStatsPanel.\(agent.rawValue)")
        // A frame saved before the title bar existed is too short for the
        // content. contentMinSize only bounds future resizes — it does not
        // re-grow an already restored frame — so lift the height explicitly as
        // well. The origin stays put, so the panel grows upward and
        // showAtMenuBar can re-pin y underneath the menu bar icon.
        p.contentMinSize = NSSize(width: 320, height: agentPanelHeight)
        if p.frame.height < agentPanelHeight {
            var f = p.frame
            f.size.height = agentPanelHeight
            p.setFrame(f, display: false)
        }

        let hv = NSHostingView(rootView: AgentStatsView(agent: agent, onClose: { [weak self] in
            self?.hide()
        }))
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
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.isShowing else { return }
            if NSApp.keyWindow == nil { self.hide() }
        }
    }
}
