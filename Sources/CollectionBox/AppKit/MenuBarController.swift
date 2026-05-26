import AppKit

/// Appearance theme options.
enum AppTheme: Int, CaseIterable, Identifiable {
    case auto = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Manages the NSStatusItem in the system menu bar.
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let store: CollectionStore
    private var edgeController: EdgeDockWindowController?

    public init(store: CollectionStore) {
        self.store = store
        super.init()
    }

    public func activate() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "收藏箱")
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleClick(_:))
            button.target = self
        }

        edgeController = EdgeDockWindowController(store: store)
        applyTheme()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showSettingsMenu()
        } else {
            edgeController?.toggle()
        }
    }

    // MARK: - Settings Menu

    private func showSettingsMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "收藏箱设置", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // Theme submenu
        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeSubmenu = NSMenu()
        let currentTheme = currentTheme()
        for option in AppTheme.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            item.state = option == currentTheme ? .on : .off
            item.representedObject = option
            themeSubmenu.addItem(item)
        }
        themeItem.submenu = themeSubmenu
        menu.addItem(themeItem)

        // Auto-hide delay submenu
        let autoHideItem = NSMenuItem(title: "自动隐藏", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentDelay = edgeController?.autoHideDelay ?? .never
        for option in AutoHideDelay.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(setAutoHide(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            item.state = option == currentDelay ? .on : .off
            item.representedObject = option
            submenu.addItem(item)
        }
        autoHideItem.submenu = submenu
        menu.addItem(autoHideItem)

        menu.addItem(.separator())

        let hideItem = NSMenuItem(title: "隐藏面板", action: #selector(hidePanel), keyEquivalent: "h")
        hideItem.target = self
        hideItem.keyEquivalentModifierMask = [.command]
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Theme

    private func currentTheme() -> AppTheme {
        let raw = UserDefaults.standard.integer(forKey: "CollectionBox.theme")
        return AppTheme(rawValue: raw) ?? .auto
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? AppTheme else { return }
        UserDefaults.standard.set(theme.rawValue, forKey: "CollectionBox.theme")
        applyTheme()
    }

    private func applyTheme() {
        let theme = currentTheme()
        NSApp.appearance = theme.appearance
    }

    // MARK: - Actions

    @objc private func setAutoHide(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? AutoHideDelay else { return }
        edgeController?.autoHideDelay = option
    }

    @objc private func hidePanel() {
        edgeController?.collapse()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
