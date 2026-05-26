import AppKit
import SwiftUI

enum AutoHideDelay: Int, CaseIterable, Identifiable {
    case never = 0, threeSeconds = 3, fiveSeconds = 5, tenSeconds = 10, thirtySeconds = 30
    var id: Int { rawValue }
    var label: String { ["不自动隐藏","3 秒后隐藏","5 秒后隐藏","10 秒后隐藏","30 秒后隐藏"][Self.allCases.firstIndex(of: self)!] }
}

enum EdgePosition: Int, CaseIterable, Identifiable {
    case right = 0, left = 1, top = 2, bottom = 3
    var id: Int { rawValue }
    var label: String { ["右侧","左侧","顶部","底部"][Self.allCases.firstIndex(of: self)!] }
}

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var triggerPanel: NSPanel?
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private let expandedWidth: CGFloat = 320
    private var collapseWorkItem: DispatchWorkItem?
    private var collapseObserver: NSObjectProtocol?

    var autoHideDelay: AutoHideDelay {
        get { AutoHideDelay(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.autoHideDelay")) ?? .never }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.autoHideDelay"); if isExpanded { scheduleCollapse() } }
    }

    var edgePosition: EdgePosition {
        get { EdgePosition(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.edgePosition")) ?? .right }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.edgePosition"); rebuildTrigger() }
    }

    init(store: CollectionStore) {
        self.store = store
        super.init()
        setupTrigger()
        // Listen for clicks outside panel
        collapseObserver = NotificationCenter.default.addObserver(forName: .panelShouldCollapse, object: nil, queue: .main) { [weak self] _ in self?.collapse() }
    }

    deinit { if let o = collapseObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: - Trigger (full-screen edge)

    private func setupTrigger() {
        guard let screen = NSScreen.main else { return }
        let f: NSRect
        let pos = edgePosition
        switch pos {
        case .right: f = NSRect(x: screen.frame.maxX - 2, y: screen.frame.minY, width: 2, height: screen.frame.height)
        case .left:  f = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 2, height: screen.frame.height)
        case .top:   f = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 2, width: screen.frame.width, height: 2)
        case .bottom:f = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 2)
        }
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar - 1  // just below menu bar but above most windows
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = false
        let hv = HoverView(frame: NSRect(x: 0, y: 0, width: f.width, height: f.height))
        hv.onHoverStart = { [weak self] in self?.expand() }
        p.contentView = hv
        self.triggerPanel = p
        p.orderFrontRegardless()
    }

    private func rebuildTrigger() {
        triggerPanel?.orderOut(nil)
        triggerPanel = nil
        setupTrigger()
    }

    // MARK: - Expand

    func expand() {
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        guard !isExpanded, let screen = NSScreen.main else { return }
        triggerPanel?.orderOut(nil)

        let h: CGFloat = 480
        let w: CGFloat = expandedWidth
        let pos = edgePosition
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

        let hv = NSHostingView(rootView: RootView(store: store))
        hv.frame = p.contentView!.bounds; hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        self.mainPanel = p; self.isExpanded = true
        scheduleCollapse()
    }

    // MARK: - Collapse

    func collapse() {
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        guard isExpanded else { return }
        mainPanel?.delegate = nil; mainPanel?.orderOut(nil); mainPanel = nil; isExpanded = false
        triggerPanel?.orderFrontRegardless()
    }

    func toggle() { if isExpanded { collapse() } else { expand() } }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let d = autoHideDelay; guard d != .never else { return }
        let w = DispatchWorkItem { [weak self] in self?.collapse() }; collapseWorkItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(d.rawValue), execute: w)
    }
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
        // Auto-collapse when focus leaves the panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.isExpanded else { return }
            // Only collapse if no window in our app is key
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
