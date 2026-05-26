import AppKit
import SwiftUI

/// Controls the edge-docked panel that expands from the right screen edge.
final class EdgeDockWindowController: NSObject {
    private let store: CollectionStore
    private var panel: NSPanel?
    private var edgeTrackingArea: NSTrackingArea?
    private(set) var isExpanded = false

    private let collapsedWidth: CGFloat = 6
    private let expandedWidth: CGFloat = 320

    init(store: CollectionStore) {
        self.store = store
        super.init()
        setupPanel()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let panelHeight: CGFloat = 480
        let panelFrame = NSRect(
            x: screen.frame.maxX - collapsedWidth,
            y: screen.frame.midY - panelHeight / 2,
            width: collapsedWidth,
            height: panelHeight
        )

        let window = NSPanel(
            contentRect: panelFrame,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false
        window.delegate = self

        let hostingView = NSHostingView(rootView: RootView(store: store))
        window.contentView = hostingView

        self.panel = window
        setupEdgeTracking()
    }

    // MARK: - Edge Tracking

    private func setupEdgeTracking() {
        guard let screen = NSScreen.main else { return }
        // Create a thin tracking area on the right edge of the screen
        let trackingRect = NSRect(
            x: screen.frame.maxX - 2,
            y: 0,
            width: 2,
            height: screen.frame.height
        )
        edgeTrackingArea = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
    }

    // MARK: - Show / Hide

    func showCollapsed() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        panel.setFrame(NSRect(
            x: screen.frame.maxX - collapsedWidth,
            y: screen.frame.midY - panel.frame.height / 2,
            width: collapsedWidth,
            height: panel.frame.height
        ), display: true)
        panel.orderFrontRegardless()
        isExpanded = false
    }

    func expand() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(
                x: screen.frame.maxX - expandedWidth,
                y: screen.frame.midY - panel.frame.height / 2,
                width: expandedWidth,
                height: panel.frame.height
            ), display: true)
        }
        isExpanded = true
    }

    func collapse() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().setFrame(NSRect(
                x: screen.frame.maxX - collapsedWidth,
                y: screen.frame.midY - panel.frame.height / 2,
                width: collapsedWidth,
                height: panel.frame.height
            ), display: true)
        }
        isExpanded = false
    }
}

// MARK: - NSWindowDelegate

extension EdgeDockWindowController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        collapse()
    }
}
