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
    private var panel: NSPanel?
    private(set) var isExpanded = false

    private let expandedWidth: CGFloat = 320
    private let triggerWidth: CGFloat = 2
    private var collapseWorkItem: DispatchWorkItem?

    /// Current auto-hide delay. Read from UserDefaults.
    var autoHideDelay: AutoHideDelay {
        get {
            let raw = UserDefaults.standard.integer(forKey: "CollectionBox.autoHideDelay")
            return AutoHideDelay(rawValue: raw) ?? .never
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "CollectionBox.autoHideDelay")
            // If currently expanded and delay changed, reschedule
            if isExpanded {
                scheduleCollapseIfNeeded()
            }
        }
    }

    init(store: CollectionStore) {
        self.store = store
        super.init()
        setupPanel()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let panelHeight: CGFloat = 480
        let frame = NSRect(
            x: screen.frame.maxX - triggerWidth,
            y: screen.frame.midY - panelHeight / 2,
            width: triggerWidth,
            height: panelHeight
        )

        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.delegate = self
        window.ignoresMouseEvents = false

        let trackingView = EdgeTrackingView(frame: window.contentView!.bounds)
        trackingView.autoresizingMask = [.width, .height]
        trackingView.onMouseEntered = { [weak self] in self?.expand() }
        window.contentView?.addSubview(trackingView)

        self.panel = window
    }

    // MARK: - Show / Hide

    func showCollapsed() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let panelHeight: CGFloat = 480
        panel.setFrame(NSRect(
            x: screen.frame.maxX - triggerWidth,
            y: screen.frame.midY - panelHeight / 2,
            width: triggerWidth,
            height: panelHeight
        ), display: true)
        panel.orderFrontRegardless()
        isExpanded = false
    }

    func expand() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard let panel = panel, let screen = NSScreen.main else { return }
        guard !isExpanded else { return }

        // Replace trigger view with actual content
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let hostingView = NSHostingView(rootView: RootView(store: store))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        // Make panel opaque and visible
        panel.isOpaque = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(
                x: screen.frame.maxX - expandedWidth,
                y: screen.frame.midY - panel.frame.height / 2,
                width: expandedWidth,
                height: panel.frame.height
            ), display: true)
        }

        isExpanded = true
        scheduleCollapseIfNeeded()
    }

    func collapse() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        guard isExpanded else { return }

        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        let panelHeight = panel.frame.height

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().setFrame(NSRect(
                x: screen.frame.maxX - triggerWidth,
                y: screen.frame.midY - panelHeight / 2,
                width: triggerWidth,
                height: panelHeight
            ), display: true)
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.panel?.contentView?.subviews.forEach { $0.removeFromSuperview() }
            self.panel?.isOpaque = false
            self.panel?.backgroundColor = .clear
            self.panel?.hasShadow = false
            self.panel?.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]

            let trackingView = EdgeTrackingView(frame: self.panel!.contentView!.bounds)
            trackingView.autoresizingMask = [.width, .height]
            trackingView.onMouseEntered = { [weak self] in self?.expand() }
            self.panel?.contentView?.addSubview(trackingView)

            self.isExpanded = false
        })
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    // MARK: - Auto-hide scheduling

    private func scheduleCollapseIfNeeded() {
        collapseWorkItem?.cancel()
        let delay = autoHideDelay
        guard delay != .never else { return }

        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .delay(delay), execute: work)
    }
}

// MARK: - Delay helper

private extension Double {
    static func delay(_ option: AutoHideDelay) -> Double {
        Double(option.rawValue)
    }
}

// MARK: - EdgeTrackingView

class EdgeTrackingView: NSView {
    var onMouseEntered: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTracking()
    }

    private func setupTracking() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }
}

// MARK: - NSWindowDelegate

extension EdgeDockWindowController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Don't auto-collapse on focus loss — user may be dragging a file
    }
}
