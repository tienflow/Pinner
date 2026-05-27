import AppKit
import SwiftUI

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private let expandedWidth: CGFloat = 320
    private var collapseObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    /// When true, clicking outside won't hide the panel.
    var isPinned = false {
        didSet { UserDefaults.standard.set(isPinned, forKey: "CollectionBox.isPinned") }
    }

    init(store: CollectionStore) {
        self.store = store
        self.isPinned = UserDefaults.standard.bool(forKey: "CollectionBox.isPinned")
        super.init()
        collapseObserver = NotificationCenter.default.addObserver(forName: .panelShouldCollapse, object: nil, queue: .main) { [weak self] _ in self?.collapse() }
    }

    deinit { if let o = collapseObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: - Expand

    func expand() {
        guard !isExpanded else { return }
        store.refreshAll()

        let h: CGFloat = 480, w: CGFloat = expandedWidth
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let screenMidX = screen.frame.midX
        let x: CGFloat
        if mouse.x < screenMidX { x = mouse.x + 4 } else { x = mouse.x - w - 4 }
        let y: CGFloat
        if mouse.y - h < screen.frame.minY { y = screen.frame.minY + 4 }
        else if mouse.y > screen.frame.maxY - h/2 { y = screen.frame.maxY - h - 4 }
        else { y = mouse.y - h/2 }
        let f = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: f)
    }

    /// Expand at menu bar button position (right side of the button)
    func expandAtMenuBar(buttonFrame: NSRect) {
        guard !isExpanded else { return }
        store.refreshAll()

        let h: CGFloat = 480, w: CGFloat = expandedWidth
        // Panel appears to the right of the menu bar icon
        let x = buttonFrame.maxX + 4
        // Vertically aligned with the button, extend downward
        let y = buttonFrame.origin.y - h + buttonFrame.height
        let f = NSRect(x: x, y: y, width: w, height: h)

        showPanel(in: f)
    }

    private func showPanel(in frame: NSRect) {
        let p = KeyPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating; p.isOpaque = true; p.backgroundColor = .windowBackgroundColor; p.hasShadow = true
        p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isMovableByWindowBackground = false; p.delegate = self

        let hv = NSHostingView(rootView: RootView(store: store, onPinToggle: { [weak self] in self?.isPinned.toggle() }))
        hv.frame = p.contentView!.bounds; hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.mainPanel = p; self.isExpanded = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 48 && self?.isExpanded == true {
                let key = event.modifierFlags.contains(.shift) ? "shiftTab" : "tab"
                NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": key])
                return nil
            }
            return event
        }
    }

    // MARK: - Collapse

    func collapse() {
        guard isExpanded else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        mainPanel?.delegate = nil; mainPanel?.orderOut(nil); mainPanel = nil; isExpanded = false
    }

    func toggle() { if isExpanded { collapse() } else { expand() } }
}

// MARK: - KeyPanel

final class KeyPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        let key: String?
        switch event.keyCode {
        case 126: key = "up"; case 125: key = "down"; case 124: key = "right"; case 123: key = "left"
        case 36: key = "return"; case 49: key = "space"; case 53: key = "escape"
        default: key = nil
        }
        if let key = key { NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": key]) }
        else { super.keyDown(with: event) }
    }
}

// MARK: - NSWindowDelegate

extension EdgeDockWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { mainPanel?.delegate = nil; collapse() }
    func windowDidResignKey(_ notification: Notification) {
        guard isExpanded, !isPinned else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isExpanded, !self.isPinned else { return }
            if NSApp.keyWindow == nil { self.collapse() }
        }
    }
}
