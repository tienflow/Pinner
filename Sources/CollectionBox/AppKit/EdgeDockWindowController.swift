import AppKit
import SwiftUI
import Quartz

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private var expandedWidth: CGFloat { savedSize.width }
    private var expandedHeight: CGFloat { savedSize.height }
    private var collapseObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private let quickLookSource = QuickLookDataSource()

    private static let windowStateKey = "CollectionBox.windowState"

    private var savedSize: NSSize {
        if let data = UserDefaults.standard.data(forKey: Self.windowStateKey),
           let ws = try? JSONDecoder().decode(WindowState.self, from: data),
           ws.width >= 280, ws.height >= 400 {
            return NSSize(width: ws.width, height: ws.height)
        }
        return NSSize(width: WindowState.defaultState.width, height: WindowState.defaultState.height)
    }

    private func persistSize(of window: NSWindow) {
        let ws = WindowState(width: Double(window.frame.width), height: Double(window.frame.height))
        if let data = try? JSONEncoder().encode(ws) {
            UserDefaults.standard.set(data, forKey: Self.windowStateKey)
        }
    }

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
        Task { await store.refreshAllAsync() }

        let h = expandedHeight, w = expandedWidth
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
        Task { await store.refreshAllAsync() }

        let h = expandedHeight, w = expandedWidth
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
        p.quickLookSource = quickLookSource

        let hv = NSHostingView(rootView: RootView(
            store: store,
            onPinToggle: { [weak self] in self?.isPinned.toggle() },
            onQuickLook: { [weak self] ids in self?.toggleQuickLook(for: ids) }
        ))
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

    // MARK: - Quick Look

    private func toggleQuickLook(for entryIDs: [UUID]) {
        guard mainPanel != nil else { return }
        let ids = Set(entryIDs)
        Task { @MainActor in
            let urls: [URL] = store.tabs
                .flatMap { $0.entries }
                .filter { ids.contains($0.id) }
                .compactMap { BookmarkService.resolveURL($0.bookmarkData) }
            guard !urls.isEmpty else { return }
            quickLookSource.items = urls
            if QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().orderOut(nil)
            } else {
                QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Collapse

    func collapse() {
        guard isExpanded else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let panel = mainPanel { persistSize(of: panel) }
        mainPanel?.delegate = nil; mainPanel?.orderOut(nil); mainPanel = nil; isExpanded = false
    }

    func toggle() { if isExpanded { collapse() } else { expand() } }
}

// MARK: - Quick Look Data Source

final class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}

// MARK: - KeyPanel

final class KeyPanel: NSPanel {
    weak var quickLookSource: QuickLookDataSource?

    override func keyDown(with event: NSEvent) {
        let key: String?
        switch event.keyCode {
        case 126: key = "up"; case 125: key = "down"; case 124: key = "right"; case 123: key = "left"
        case 36: key = "return"; case 49: key = "space"; case 53: key = "escape"
        case 51: key = "delete"
        default: key = nil
        }
        // ⌘Z undo / ⌘Y Quick Look (skipped while a text field handles them itself)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            if event.charactersIgnoringModifiers == "z" { NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": "undo"]); return }
            if event.charactersIgnoringModifiers == "y" { NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": "quicklook"]); return }
        }
        if let key = key { NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": key]) }
        else { super.keyDown(with: event) }
    }

    // MARK: Quick Look panel control (responder chain)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookSource
        panel.delegate = quickLookSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - NSWindowDelegate

extension EdgeDockWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { mainPanel?.delegate = nil; collapse() }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let panel = mainPanel { persistSize(of: panel) }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look overlays the panel; handing key status to it must not collapse us.
        if NSApp.keyWindow is QLPreviewPanel { return }
        guard isExpanded, !isPinned else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.isExpanded, !self.isPinned else { return }
            if NSApp.keyWindow is QLPreviewPanel { return }
            if NSApp.keyWindow == nil { self.collapse() }
        }
    }
}
