import AppKit

/// Manages the NSStatusItem in the system menu bar and coordinates show/hide.
public final class MenuBarController {
    private var statusItem: NSStatusItem?
    private let store: CollectionStore
    private var edgeController: EdgeDockWindowController?

    public init(store: CollectionStore) {
        self.store = store
    }

    public func activate() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "收藏箱")
            button.action = #selector(togglePanel)
            button.target = self
        }

        edgeController = EdgeDockWindowController(store: store)
        edgeController?.showCollapsed()
    }

    @objc private func togglePanel() {
        guard let controller = edgeController else { return }
        if controller.isExpanded {
            controller.collapse()
        } else {
            controller.expand()
        }
    }
}
