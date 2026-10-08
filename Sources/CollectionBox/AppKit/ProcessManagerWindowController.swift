import AppKit
import SwiftUI

@MainActor
public final class ProcessManagerWindowController: NSObject, NSWindowDelegate {
    public static let shared = ProcessManagerWindowController()

    private let service: ProcessManagerService
    private var panel: NSPanel?
    public private(set) var isShowing = false
    private var mouseMonitor: Any?

    public init(service: ProcessManagerService = .shared) {
        self.service = service
        super.init()
    }

    public func toggle() {
        if isShowing { hide() } else { showAtMouse() }
    }

    public func showAtMouse() {
        if isShowing { hide(); return }

        let w: CGFloat = 720, h: CGFloat = 600
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]

        let x = screen.frame.midX - w / 2
        let y = screen.frame.midY - h / 2 + 20
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame)
    }

    public func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 720, h: CGFloat = 600
        let x = min(buttonFrame.maxX - w, (NSScreen.main?.frame.maxX ?? 1200) - w - 10)
        let y = buttonFrame.origin.y - h - 4
        let frame = NSRect(x: max(10, x), y: y, width: w, height: h)

        showPanel(in: frame)
    }

    private func showPanel(in frame: NSRect) {
        let p = EscDismissablePanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.minSize = NSSize(width: 600, height: 480)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.title = "进程"
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

        let contentView = ProcessManagerView(service: service) { [weak self] in
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

        // Start active monitoring only when panel is visible
        service.startMonitoring(interval: 2.0)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
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
        // Stop monitoring when closed to preserve battery and CPU
        service.stopMonitoring()

        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    public func windowWillClose(_ notification: Notification) {
        hide()
    }
}
