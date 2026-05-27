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
    private var hotkeyManager: HotkeyManager?

    public init(store: CollectionStore) { self.store = store; super.init() }

    public func activate() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let b = statusItem?.button else { return }
        if let sym = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Pinner") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let img = sym.withSymbolConfiguration(config) ?? sym
            img.isTemplate = true
            b.image = img
        }
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.action = #selector(handleClick(_:))
        b.target = self
        edgeController = EdgeDockWindowController(store: store)
        hotkeyManager = HotkeyManager()
        hotkeyManager?.onHotkeyTriggered = { [weak self] in self?.edgeController?.expand() }
        hotkeyManager?.register()
        applyTheme()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp { showMenu() } else {
            // Get menu bar button position for panel placement
            if let btn = statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                edgeController?.expandAtMenuBar(buttonFrame: btnFrame)
            } else {
                edgeController?.toggle()
            }
        }
    }

    private func showMenu() {
        let m = NSMenu()
        let header = NSMenuItem(title: "Pinner 设置", action: nil, keyEquivalent: "")
        header.isEnabled = false; m.addItem(header)
        m.addItem(.separator())

        // Hotkey
        let hotkeyItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let hotkeySub = NSMenu()
        let curCombo = hotkeyManager?.currentCombo ?? HotkeyManager.defaultCombo
        let displayTitle = curCombo.displayString
        let showCurrent = NSMenuItem(title: "当前: \(displayTitle)", action: nil, keyEquivalent: "")
        showCurrent.isEnabled = false; hotkeySub.addItem(showCurrent)
        hotkeySub.addItem(.separator())
        let recordItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordHotkey), keyEquivalent: "")
        recordItem.target = self; hotkeySub.addItem(recordItem)
        let clearItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearHotkey), keyEquivalent: "")
        clearItem.target = self; hotkeySub.addItem(clearItem)
        hotkeyItem.submenu = hotkeySub; m.addItem(hotkeyItem)

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

        m.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏面板", action: #selector(hidePanel), keyEquivalent: "h")
        hide.target = self; hide.keyEquivalentModifierMask = [.command]; m.addItem(hide)
        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; quit.keyEquivalentModifierMask = [.command]; m.addItem(quit)

        statusItem?.menu = m; statusItem?.button?.performClick(nil); statusItem?.menu = nil
    }

    @objc private func recordHotkey() {
        // Use a simple window to capture key events
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                             styleMask: [.titled, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .floating
        window.title = "设置快捷键"
        window.isReleasedWhenClosed = false
        window.center()

        let label = NSTextField(labelWithString: "请按下快捷键组合")
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 80, width: 260, height: 20)

        let keyLabel = NSTextField(labelWithString: "等待按键...")
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        keyLabel.alignment = .center
        keyLabel.frame = NSRect(x: 20, y: 30, width: 260, height: 40)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(keyLabel)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                if let m = monitor { NSEvent.removeMonitor(m) }
                window.close()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty {
                keyLabel.stringValue = "请先按住修饰键"
                return event
            }
            let carbonMods = carbonModifiers(from: event.modifierFlags)
            let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            keyLabel.stringValue = combo.displayString
            // Save and close
            if let m = monitor { NSEvent.removeMonitor(m) }
            self.hotkeyManager?.save(combo: combo)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.close() }
            return nil
        }
    }

    @objc private func clearHotkey() {
        hotkeyManager?.clear()
    }

    @objc private func setTheme(_ s: NSMenuItem) {
        guard let t = s.representedObject as? AppTheme else { return }
        UserDefaults.standard.set(t.rawValue, forKey: "CollectionBox.theme"); applyTheme()
    }

    @objc private func hidePanel() { edgeController?.collapse() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func applyTheme() {
        let t = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        NSApp.appearance = t.appearance
    }
}
