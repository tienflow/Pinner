import AppKit
import SwiftUI

enum EdgePosition: Int, CaseIterable, Identifiable {
    case right = 0, left = 1, top = 2, bottom = 3
    var id: Int { rawValue }
    var label: String { ["右侧","左侧","顶部","底部"][Self.allCases.firstIndex(of: self)!] }
}

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var triggerPanels: [NSPanel] = []
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private let expandedWidth: CGFloat = 320
    private var collapseObserver: NSObjectProtocol?

    /// When true, clicking outside won't hide the panel.
    var isPinned = false {
        didSet { UserDefaults.standard.set(isPinned, forKey: "CollectionBox.isPinned") }
    }

    var edgePositions: Set<EdgePosition> {
        get {
            let raw = UserDefaults.standard.array(forKey: "CollectionBox.edgePositions") as? [Int] ?? [EdgePosition.right.rawValue]
            return Set(raw.compactMap { EdgePosition(rawValue: $0) })
        }
        set {
            UserDefaults.standard.set(Array(newValue.map(\.rawValue)), forKey: "CollectionBox.edgePositions")
            rebuildTriggers()
        }
    }

    init(store: CollectionStore) {
        self.store = store
        self.isPinned = UserDefaults.standard.bool(forKey: "CollectionBox.isPinned")
        super.init()
        setupTriggers()
        collapseObserver = NotificationCenter.default.addObserver(forName: .panelShouldCollapse, object: nil, queue: .main) { [weak self] _ in self?.collapse() }
    }

    deinit { if let o = collapseObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: - Triggers

    private func setupTriggers() { for pos in edgePositions { makeTrigger(for: pos) } }

    private func makeTrigger(for pos: EdgePosition) {
        guard let screen = NSScreen.main else { return }
        let f: NSRect
        switch pos {
        case .right: f = NSRect(x: screen.frame.maxX - 2, y: screen.frame.minY, width: 2, height: screen.frame.height)
        case .left:  f = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 2, height: screen.frame.height)
        case .top:   f = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 2, width: screen.frame.width, height: 2)
        case .bottom:f = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 2)
        }
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar - 1; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = HoverView(frame: NSRect(x: 0, y: 0, width: f.width, height: f.height))
        hv.onHoverStart = { [weak self] in self?.expand() }
        p.contentView = hv; p.orderFrontRegardless()
        triggerPanels.append(p)
    }

    private func rebuildTriggers() {
        triggerPanels.forEach { $0.orderOut(nil) }; triggerPanels.removeAll(); setupTriggers()
    }

    // MARK: - Expand

    func expand() {
        guard !isExpanded, let screen = NSScreen.main else { return }
        triggerPanels.forEach { $0.orderOut(nil) }

        let h: CGFloat = 480, w: CGFloat = expandedWidth
        let pos = edgePositions.first ?? .right
        let f: NSRect
        switch pos {
        case .right: f = NSRect(x: screen.frame.maxX - w, y: screen.frame.midY - h/2, width: w, height: h)
        case .left:  f = NSRect(x: screen.frame.minX, y: screen.frame.midY - h/2, width: w, height: h)
        case .top:   f = NSRect(x: screen.frame.midX - w/2, y: screen.frame.maxY - h, width: w, height: h)
        case .bottom:f = NSRect(x: screen.frame.midX - w/2, y: screen.frame.minY, width: w, height: h)
        }

        let p = KeyPanel(contentRect: f, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating; p.isOpaque = true; p.backgroundColor = .windowBackgroundColor; p.hasShadow = true
        p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isMovableByWindowBackground = false; p.delegate = self

        let hv = NSHostingView(rootView: RootView(store: store, onPinToggle: { [weak self] in self?.isPinned.toggle() }))
        hv.frame = p.contentView!.bounds; hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.mainPanel = p; self.isExpanded = true
    }

    // MARK: - Collapse

    func collapse() {
        guard isExpanded else { return }
        mainPanel?.delegate = nil; mainPanel?.orderOut(nil); mainPanel = nil; isExpanded = false
        triggerPanels.forEach { $0.orderFrontRegardless() }
    }

    func toggle() { if isExpanded { collapse() } else { expand() } }
}

// MARK: - KeyPanel

final class KeyPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        let key: String?
        switch event.keyCode {
        case 126: key = "up"; case 125: key = "down"; case 36: key = "return"; case 49: key = "space"
        case 53: key = "escape"; default: key = nil
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

// MARK: - HoverView

class HoverView: NSView {
    var onHoverStart: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { onHoverStart?() }
    override func mouseMoved(with event: NSEvent) { onHoverStart?() }
}
