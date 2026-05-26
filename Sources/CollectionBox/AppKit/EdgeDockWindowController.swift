import AppKit
import SwiftUI

enum AutoHideDelay: Int, CaseIterable, Identifiable {
    case never = 0
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .never: return "不自动隐藏"
        case .threeSeconds: return "3 秒后隐藏"
        case .fiveSeconds: return "5 秒后隐藏"
        case .tenSeconds: return "10 秒后隐藏"
        case .thirtySeconds: return "30 秒后隐藏"
        }
    }
}

final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var triggerPanel: NSPanel?
    private var mainPanel: NSPanel?
    private(set) var isExpanded = false
    private let expandedWidth: CGFloat = 320
    private let triggerWidth: CGFloat = 6
    private var collapseWorkItem: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var autoHideDelay: AutoHideDelay {
        get { AutoHideDelay(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.autoHideDelay")) ?? .never }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.autoHideDelay"); if isExpanded { scheduleCollapseIfNeeded() } }
    }

    init(store: CollectionStore) {
        self.store = store
        super.init()
        setupTriggerPanel()
    }

    deinit { stopMonitors() }

    // MARK: - Trigger

    private func setupTriggerPanel() {
        guard let screen = NSScreen.main else { return }
        let h: CGFloat = 480
        let f = NSRect(x: screen.frame.maxX - triggerWidth, y: screen.frame.midY - h / 2, width: triggerWidth, height: h)
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = NSColor.black.withAlphaComponent(0.15)
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.ignoresMouseEvents = false
        let hv = HoverView(frame: NSRect(x: 0, y: 0, width: triggerWidth, height: h))
        hv.onHoverStart = { [weak self] in self?.expand() }
        p.contentView = hv
        self.triggerPanel = p
        p.orderFrontRegardless()
    }

    // MARK: - Expand

    func expand() {
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        guard !isExpanded else { return }
        guard let screen = NSScreen.main else { return }
        triggerPanel?.orderOut(nil)

        let h: CGFloat = 480
        let f = NSRect(x: screen.frame.maxX - expandedWidth, y: screen.frame.midY - h / 2, width: expandedWidth, height: h)
        let p = NSPanel(contentRect: f, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = true
        p.backgroundColor = NSColor.windowBackgroundColor
        p.hasShadow = true
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.delegate = self

        let hv = NSHostingView(rootView: RootView(store: store))
        hv.frame = p.contentView!.bounds
        hv.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(hv)

        p.makeKeyAndOrderFront(nil)
        self.mainPanel = p
        self.isExpanded = true

        startMonitors()
        scheduleCollapseIfNeeded()
    }

    // MARK: - Collapse

    func collapse() {
        collapseWorkItem?.cancel(); collapseWorkItem = nil
        guard isExpanded else { return }
        stopMonitors()
        mainPanel?.delegate = nil
        mainPanel?.orderOut(nil)
        mainPanel = nil
        isExpanded = false
        triggerPanel?.orderFrontRegardless()
    }

    func toggle() { if isExpanded { collapse() } else { expand() } }

    // MARK: - Key Monitors (local + global to cover all cases)

    private func startMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
        }
    }

    private func stopMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) {
        guard isExpanded else { return }
        let key: String?
        switch event.keyCode {
        case 126: key = "up"
        case 125: key = "down"
        case 36:  key = "return"
        case 49:  key = "space"
        case 53:  collapse(); return
        default: key = nil
        }
        if let key = key {
            NotificationCenter.default.post(name: .collectionBoxKeyDown, object: nil, userInfo: ["key": key])
        }
    }

    // MARK: - Auto-hide

    private func scheduleCollapseIfNeeded() {
        collapseWorkItem?.cancel()
        let delay = autoHideDelay
        guard delay != .never else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay.rawValue), execute: work)
    }
}

// MARK: - NSWindowDelegate

extension EdgeDockWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        mainPanel?.delegate = nil
        collapse()
    }
    func windowDidResignKey(_ notification: Notification) {}
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
