import AppKit
import SwiftUI

enum AutoHideDelay: Int, CaseIterable, Identifiable {
    case never = 0, threeSeconds = 3, fiveSeconds = 5, tenSeconds = 10, thirtySeconds = 30
    var id: Int { rawValue }
    var label: String { ["不自动隐藏","3 秒后隐藏","5 秒后隐藏","10 秒后隐藏","30 秒后隐藏"][Self.allCases.firstIndex(of: self)!] }
}

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var triggerPanel: NSPanel?
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private let expandedWidth: CGFloat = 320, triggerWidth: CGFloat = 6
    private var collapseWorkItem: DispatchWorkItem?

    var autoHideDelay: AutoHideDelay {
        get { AutoHideDelay(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.autoHideDelay")) ?? .never }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.autoHideDelay"); if isExpanded { scheduleCollapse() } }
    }

    init(store: CollectionStore) { self.store = store; super.init(); setupTrigger() }

    // MARK: - Trigger

    private func setupTrigger() {
        guard let screen = NSScreen.main else { return }
        let h: CGFloat = 480
        let f = NSRect(x: screen.frame.maxX - triggerWidth, y: screen.frame.midY - h/2, width: triggerWidth, height: h)
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = NSColor.black.withAlphaComponent(0.15)
        p.hasShadow = false; p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hv = HoverView(frame: NSRect(x: 0, y: 0, width: triggerWidth, height: h))
        hv.onHoverStart = { [weak self] in self?.expand() }
        p.contentView = hv; triggerPanel = p; p.orderFrontRegardless()
    }

    // MARK: - Expand

    func expand() {
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        guard !isExpanded, let screen = NSScreen.main else { return }
        triggerPanel?.orderOut(nil)

        let h: CGFloat = 480
        let f = NSRect(x: screen.frame.maxX - expandedWidth, y: screen.frame.midY - h/2, width: expandedWidth, height: h)
        let p = KeyPanel(contentRect: f, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating; p.isOpaque = true; p.backgroundColor = .windowBackgroundColor; p.hasShadow = true
        p.titlebarAppearsTransparent = true; p.titleVisibility = .hidden; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.isMovableByWindowBackground = false; p.delegate = self

        let hv = NSHostingView(rootView: RootView(store: store))
        hv.frame = p.contentView!.bounds; hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        // Activate app so keyboard events reach KeyPanel.keyDown
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)

        self.mainPanel = p; self.isExpanded = true
        NotificationCenter.default.addObserver(forName: .panelShouldCollapse, object: nil, queue: .main) { [weak self] _ in self?.collapse() }
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

extension EdgeDockWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { mainPanel?.delegate = nil; collapse() }
}

class HoverView: NSView {
    var onHoverStart: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved], owner: self, userInfo: nil)) }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with event: NSEvent) { onHoverStart?() }
    override func mouseMoved(with event: NSEvent) { onHoverStart?() }
}
