import AppKit
import SwiftUI

/// Auto-hide delay options.
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

/// Controls the edge-docked panel with configurable auto-hide.
final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var triggerPanel: NSPanel?   // thin strip for hover detection
    private var mainPanel: NSPanel?      // the actual expanded panel
    private(set) var isExpanded = false

    private let expandedWidth: CGFloat = 320
    private let triggerWidth: CGFloat = 6
    private var collapseWorkItem: DispatchWorkItem?

    var autoHideDelay: AutoHideDelay {
        get {
            let raw = UserDefaults.standard.integer(forKey: "CollectionBox.autoHideDelay")
            return AutoHideDelay(rawValue: raw) ?? .never
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.autoHideDelay")
            if isExpanded { scheduleCollapseIfNeeded() }
        }
    }

    init(store: CollectionStore) {
        self.store = store
        super.init()
        setupTriggerPanel()
    }

    // MARK: - Trigger Panel (collapsed state)

    private func setupTriggerPanel() {
        guard let screen = NSScreen.main else { return }
        let h: CGFloat = 480
        let frame = NSRect(
            x: screen.frame.maxX - triggerWidth,
            y: screen.frame.midY - h / 2,
            width: triggerWidth,
            height: h
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.15)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false

        let hoverView = HoverView(frame: NSRect(x: 0, y: 0, width: triggerWidth, height: h))
        hoverView.onHoverStart = { [weak self] in
            self?.expand()
        }
        panel.contentView = hoverView

        self.triggerPanel = panel
        panel.orderFrontRegardless()
    }

    // MARK: - Expand

    func expand() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard !isExpanded else { return }
        guard let screen = NSScreen.main else { return }

        // Hide trigger
        triggerPanel?.orderOut(nil)

        let h: CGFloat = 480
        let frame = NSRect(
            x: screen.frame.maxX - expandedWidth,
            y: screen.frame.midY - h / 2,
            width: expandedWidth,
            height: h
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self

        let hostingView = NSHostingView(rootView: RootView(store: store))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        panel.orderFrontRegardless()
        self.mainPanel = panel
        self.isExpanded = true

        scheduleCollapseIfNeeded()
    }

    // MARK: - Collapse

    func collapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard isExpanded else { return }

        mainPanel?.orderOut(nil)
        mainPanel = nil
        isExpanded = false

        // Re-show trigger
        triggerPanel?.orderFrontRegardless()
    }

    func toggle() {
        if isExpanded { collapse() } else { expand() }
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
    func windowDidResignKey(_ notification: Notification) {
        // Don't auto-collapse on focus loss
    }
}

// MARK: - HoverView

class HoverView: NSView {
    var onHoverStart: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverStart?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverStart?()
    }
}
