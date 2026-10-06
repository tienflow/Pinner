import AppKit
import SwiftUI

private final class InputStatsKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class InputStatsWindowController: NSObject, NSWindowDelegate {
    public static let shared = InputStatsWindowController()

    private let service: InputStatsService
    private var panel: NSPanel?
    public private(set) var isShowing = false
    private var mouseMonitor: Any?

    public init(service: InputStatsService) {
        self.service = service
        super.init()
    }

    public convenience override init() {
        self.init(service: InputStatsService.shared)
    }

    public func toggle() {
        if isShowing { hide() } else { showAtMouse() }
    }

    public func showAtMouse() {
        if isShowing { hide(); return }

        let w: CGFloat = 460, h: CGFloat = 640
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]

        // Center on screen or near mouse
        let x = screen.frame.midX - w / 2
        let y = screen.frame.midY - h / 2 + 30
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    public func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 460, h: CGFloat = 640
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 4
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    private func showPanel(in frame: NSRect) {
        let p = InputStatsKeyPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.minSize = NSSize(width: 440, height: 500)
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

        let contentView = InputStatsView(service: service) { [weak self] in
            self?.hide()
        }

        let hv = NSHostingView(rootView: contentView)
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
        hide()
    }
}
