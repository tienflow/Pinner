import AppKit
import SwiftUI

/// NSPanel subclass that can become key window (needed for text input in floating panels).
private final class OTPKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OTPWindowController: NSObject {
    private let store: OTPStore
    private var panel: NSPanel?
    private var addPanel: NSWindow?
    private(set) var isShowing = false
    private var mouseMonitor: Any?

    init(store: OTPStore) {
        self.store = store
        super.init()
    }

    func toggle(autoCopy: Bool = false) {
        if isShowing { hide() } else { showAtMouse(autoCopy: autoCopy) }
    }

    /// Show panel below the menu bar icon.
    func showAtMenuBar(buttonFrame: NSRect) {
        if isShowing { hide(); return }

        let w: CGFloat = 280, h: CGFloat = 400
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame, autoCopy: false)
    }

    /// Show panel near the mouse cursor.
    func showAtMouse(autoCopy: Bool = false) {
        if isShowing { hide(); return }

        let w: CGFloat = 280, h: CGFloat = 400
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let x: CGFloat
        if mouse.x < screen.frame.midX { x = mouse.x + 4 } else { x = mouse.x - w - 4 }
        let y: CGFloat
        if mouse.y - h < screen.frame.minY { y = screen.frame.minY + 4 }
        else if mouse.y > screen.frame.maxY - h / 2 { y = screen.frame.maxY - h - 4 }
        else { y = mouse.y - h / 2 }
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame, autoCopy: autoCopy)
    }

    private func showPanel(in frame: NSRect, autoCopy: Bool) {
        let p = OTPKeyPanel(contentRect: frame,
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

        let hv = NSHostingView(rootView: OTPView(store: store, autoCopyOnAppear: autoCopy, onAddRequested: { [weak self] in
            self?.showAddWindow()
        }))
        hv.frame = p.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
        self.isShowing = true

        // Dismiss when clicking outside the app (e.g. on a browser window)
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
        addPanel?.close()
        addPanel = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        isShowing = false
    }

    // MARK: - Add Account Window

    private func showAddWindow() {
        // Close existing add window if any
        addPanel?.close()
        addPanel = nil

        let w: CGFloat = 440, h: CGFloat = 420
        let mainFrame = panel?.frame ?? NSRect(x: 0, y: 0, width: 280, height: 400)
        let x = mainFrame.midX - w / 2
        let y = mainFrame.midY + mainFrame.height / 2 - h / 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        // Use NSWindow (not NSPanel) so Edit menu shortcuts (Cmd+V etc.) work
        let w2 = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: true)
        w2.title = "添加 OTP 账户"
        w2.isReleasedWhenClosed = false
        w2.level = .floating
        w2.backgroundColor = .windowBackgroundColor
        w2.hasShadow = true
        w2.center()

        let addView = AddOTPView(isPresented: Binding(
            get: { self.addPanel != nil },
            set: { if !$0 { self.addPanel?.close(); self.addPanel = nil } }
        )) { [weak self] account in
            self?.store.addAccount(account)
            DispatchQueue.main.async {
                self?.addPanel?.close()
                self?.addPanel = nil
            }
        }

        let hv = NSHostingView(rootView: addView)
        hv.frame = w2.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        w2.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        w2.makeKeyAndOrderFront(nil)
        self.addPanel = w2
    }
}

extension OTPWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let sender = notification.object as? NSPanel, sender === panel {
            panel?.delegate = nil
            isShowing = false
        }
        if let sender = notification.object as? NSWindow, sender === addPanel {
            addPanel = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            guard self.isShowing else { return }
            // Don't hide if the add window just took focus
            if self.addPanel != nil, NSApp.keyWindow === self.addPanel { return }
            // Hide if no window is key (clicked outside) or another unrelated window became key
            self.hide()
        }
    }
}
