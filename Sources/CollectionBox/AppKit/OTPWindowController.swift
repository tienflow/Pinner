import AppKit
import SwiftUI

private final class OTPEscDismissablePanel: EscDismissablePanel {
    var onEscape: (() -> Bool)?

    override func handleEscape() {
        if onEscape?() == true { return }
        super.handleEscape()
    }
}

/// NSPanel subclass that can become key window (needed for text input in floating panels).
final class OTPWindowController: NSObject {
    private let store: OTPStore
    private var panel: OTPEscDismissablePanel?
    private var addPanel: NSWindow?
    private(set) var isShowing = false
    private var isAdding = false
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

        let w: CGFloat = 330, h: CGFloat = 440
        let x = buttonFrame.maxX - w
        let y = buttonFrame.origin.y - h - 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: frame, autoCopy: false)
    }

    /// Show panel near the mouse cursor.
    func showAtMouse(autoCopy: Bool = false) {
        if isShowing { hide(); return }

        let w: CGFloat = 330, h: CGFloat = 440
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
        let p = OTPEscDismissablePanel(contentRect: frame,
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

        let hv = NSHostingView(rootView: OTPView(
            store: store,
            autoCopyOnAppear: autoCopy,
            onClose: { [weak self] in
                self?.hide()
            },
            onAddingStateChanged: { [weak self] adding in
                self?.isAdding = adding
            }
        ))
        hv.frame = p.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.panel = p
        self.isShowing = true
        self.isAdding = false

        // Dismiss when clicking outside the app (e.g. on a browser window)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self else { return }
            if self.isAdding || self.addPanel != nil { return }
            self.hide()
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
        isAdding = false
    }

    // MARK: - Add Account Window

    public func showAddWindow() {
        // Close existing add window if any
        addPanel?.close()
        addPanel = nil

        let w: CGFloat = 440, h: CGFloat = 420
        let mainFrame = panel?.frame ?? NSRect(x: 0, y: 0, width: 280, height: 400)
        let x = mainFrame.midX - w / 2
        let y = mainFrame.midY + mainFrame.height / 2 - h / 2
        let frame = NSRect(x: x, y: y, width: w, height: h)

        // EscDismissableWindow is the shared floating-window class: it forwards
        // ⌘V/⌘A to the main menu (which the paste field needs under
        // `.accessory`) and adds the Esc dismissal every other panel has.
        let w2 = EscDismissableWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        w2.title = "添加 OTP 账户"
        w2.isReleasedWhenClosed = false
        w2.level = .floating
        w2.isOpaque = false
        w2.backgroundColor = .clear
        w2.hasShadow = true
        w2.titlebarAppearsTransparent = true
        w2.titleVisibility = .hidden
        w2.standardWindowButton(.closeButton)?.isHidden = true
        w2.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w2.standardWindowButton(.zoomButton)?.isHidden = true
        w2.hidesOnDeactivate = false
        w2.isMovableByWindowBackground = true
        w2.center()

        let addView = AddOTPView(isPresented: Binding(
            get: { self.addPanel != nil },
            set: { [weak self] isPres in
                if !isPres {
                    self?.addPanel?.close()
                    self?.addPanel = nil
                    self?.ensurePanelVisibleAndKey()
                }
            }
        )) { [weak self] account in
            guard let self = self else { return }
            self.store.addAccount(account)
            DispatchQueue.main.async {
                self.addPanel?.close()
                self.addPanel = nil
                self.ensurePanelVisibleAndKey()
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

    private func ensurePanelVisibleAndKey() {
        NSApp.activate(ignoringOtherApps: true)
        if let panel = self.panel {
            panel.makeKeyAndOrderFront(nil)
            self.isShowing = true
        } else {
            self.showAtMouse(autoCopy: false)
        }
    }
}

extension OTPWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let sender = notification.object as? NSPanel, sender === panel {
            hide()
        }
        if let sender = notification.object as? NSWindow, sender === addPanel {
            addPanel = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            guard self.isShowing else { return }
            // Don't hide if adding an account or if add window is open
            if self.isAdding || self.addPanel != nil { return }
            // Hide if no window is key (clicked outside) or another unrelated window became key
            self.hide()
        }
    }
}
