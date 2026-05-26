import AppKit

enum AppTheme: Int, CaseIterable, Identifiable {
    case auto = 0, light = 1, dark = 2
    var id: Int { rawValue }
    var label: String { ["自动","浅色","深色"][Self.allCases.firstIndex(of: self)!] }
    var appearance: NSAppearance? {
        switch self { case .auto: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let store: CollectionStore
    private var edgeController: EdgeDockWindowController?

    public init(store: CollectionStore) { self.store = store; super.init() }

    public func activate() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem?.button {
            b.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "收藏箱")
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.action = #selector(handleClick(_:)); b.target = self
        }
        edgeController = EdgeDockWindowController(store: store)
        applyTheme()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp { showMenu() } else { edgeController?.toggle() }
    }

    private func showMenu() {
        let m = NSMenu()
        let header = NSMenuItem(title: "收藏箱设置", action: nil, keyEquivalent: "")
        header.isEnabled = false; m.addItem(header)
        m.addItem(.separator())

        // Edge positions (multi-select)
        let edgeItem = NSMenuItem(title: "触发边缘", action: nil, keyEquivalent: "")
        let edgeSub = NSMenu()
        let cur = edgeController?.edgePositions ?? [.right]
        for p in EdgePosition.allCases {
            let i = NSMenuItem(title: p.label, action: #selector(toggleEdge(_:)), keyEquivalent: "")
            i.target = self; i.tag = p.rawValue; i.state = cur.contains(p) ? .on : .off
            i.representedObject = p; edgeSub.addItem(i)
        }
        edgeItem.submenu = edgeSub; m.addItem(edgeItem)

        // Theme
        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeSub = NSMenu()
        let curTheme = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        for t in AppTheme.allCases {
            let i = NSMenuItem(title: t.label, action: #selector(setTheme(_:)), keyEquivalent: "")
            i.target = self; i.tag = t.rawValue; i.state = t == curTheme ? .on : .off; i.representedObject = t
            themeSub.addItem(i)
        }
        themeItem.submenu = themeSub; m.addItem(themeItem)

        // Auto-hide
        let hideItem = NSMenuItem(title: "自动隐藏", action: nil, keyEquivalent: "")
        let hideSub = NSMenu()
        let curDelay = edgeController?.autoHideDelay ?? .never
        for d in AutoHideDelay.allCases {
            let i = NSMenuItem(title: d.label, action: #selector(setAutoHide(_:)), keyEquivalent: "")
            i.target = self; i.tag = d.rawValue; i.state = d == curDelay ? .on : .off; i.representedObject = d
            hideSub.addItem(i)
        }
        hideItem.submenu = hideSub; m.addItem(hideItem)

        m.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏面板", action: #selector(hidePanel), keyEquivalent: "h")
        hide.target = self; hide.keyEquivalentModifierMask = [.command]; m.addItem(hide)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; quit.keyEquivalentModifierMask = [.command]; m.addItem(quit)

        statusItem?.menu = m; statusItem?.button?.performClick(nil); statusItem?.menu = nil
    }

    // MARK: - Actions

    @objc private func toggleEdge(_ s: NSMenuItem) {
        guard let pos = s.representedObject as? EdgePosition else { return }
        var cur = edgeController?.edgePositions ?? []
        if cur.contains(pos) { cur.remove(pos) } else { cur.insert(pos) }
        if cur.isEmpty { cur = [.right] } // at least one edge must be active
        edgeController?.edgePositions = cur
    }

    @objc private func setTheme(_ s: NSMenuItem) {
        guard let t = s.representedObject as? AppTheme else { return }
        UserDefaults.standard.set(t.rawValue, forKey: "CollectionBox.theme"); applyTheme()
    }

    @objc private func setAutoHide(_ s: NSMenuItem) {
        guard let d = s.representedObject as? AutoHideDelay else { return }
        edgeController?.autoHideDelay = d
    }

    @objc private func hidePanel() { edgeController?.collapse() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func applyTheme() {
        let t = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        NSApp.appearance = t.appearance
    }
}
