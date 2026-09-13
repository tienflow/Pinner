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
    private let otpStore = OTPStore()
    private var otpController: OTPWindowController?
    private var otpHotkeyManager: OTPHotkeyManager?
    private var codexStatsController: CodexStatsWindowController?
    private var codexStatsHotkeyManager: CodexStatsHotkeyManager?
    private var geminiStatsController: GeminiStatsWindowController?
    private var geminiStatsHotkeyManager: GeminiStatsHotkeyManager?
    private var workbuddyStatsController: WorkBuddyStatsWindowController?
    private var workbuddyStatsHotkeyManager: WorkBuddyStatsHotkeyManager?

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

        otpController = OTPWindowController(store: otpStore)
        otpHotkeyManager = OTPHotkeyManager()
        otpHotkeyManager?.onHotkeyTriggered = { [weak self] in self?.otpController?.toggle(autoCopy: true) }
        otpHotkeyManager?.register()

        codexStatsController = CodexStatsWindowController()
        codexStatsHotkeyManager = CodexStatsHotkeyManager()
        codexStatsHotkeyManager?.onHotkeyTriggered = { [weak self] in self?.showCodexStats() }
        codexStatsHotkeyManager?.register()

        geminiStatsController = GeminiStatsWindowController()
        geminiStatsHotkeyManager = GeminiStatsHotkeyManager()
        geminiStatsHotkeyManager?.onHotkeyTriggered = { [weak self] in self?.showGeminiStats() }
        geminiStatsHotkeyManager?.register()

        workbuddyStatsController = WorkBuddyStatsWindowController()
        workbuddyStatsHotkeyManager = WorkBuddyStatsHotkeyManager()
        workbuddyStatsHotkeyManager?.onHotkeyTriggered = { [weak self] in self?.showWorkBuddyStats() }
        workbuddyStatsHotkeyManager?.register()

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
        let header = NSMenuItem(title: "总览", action: #selector(openDashboard), keyEquivalent: "")
        header.target = self; m.addItem(header)
        m.addItem(.separator())

        // Collection
        let collectionItem = NSMenuItem(title: "收藏夹", action: #selector(openCollection), keyEquivalent: "")
        collectionItem.target = self; m.addItem(collectionItem)
        let collectionHotkeyItem = NSMenuItem(title: "收藏夹快捷键", action: nil, keyEquivalent: "")
        let collectionHotkeySub = NSMenu()
        let curCombo = hotkeyManager?.currentCombo ?? HotkeyManager.defaultCombo
        let showCurrent = NSMenuItem(title: "当前: \(curCombo.displayString)", action: nil, keyEquivalent: "")
        showCurrent.isEnabled = false; collectionHotkeySub.addItem(showCurrent)
        collectionHotkeySub.addItem(.separator())
        let recordItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordHotkey), keyEquivalent: "")
        recordItem.target = self; collectionHotkeySub.addItem(recordItem)
        let clearItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearHotkey), keyEquivalent: "")
        clearItem.target = self; collectionHotkeySub.addItem(clearItem)
        collectionHotkeyItem.submenu = collectionHotkeySub; m.addItem(collectionHotkeyItem)

        m.addItem(.separator())

        // OTP
        let otpItem = NSMenuItem(title: "OTP 验证码", action: #selector(showOTP), keyEquivalent: "")
        otpItem.target = self; m.addItem(otpItem)
        let otpHotkeyItem = NSMenuItem(title: "OTP 快捷键", action: nil, keyEquivalent: "")
        let otpHotkeySub = NSMenu()
        let curOTPCombo = otpHotkeyManager?.currentCombo ?? OTPHotkeyManager.defaultCombo
        let showOTPCurrent = NSMenuItem(title: "当前: \(curOTPCombo.displayString)", action: nil, keyEquivalent: "")
        showOTPCurrent.isEnabled = false; otpHotkeySub.addItem(showOTPCurrent)
        otpHotkeySub.addItem(.separator())
        let recordOTPItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordOTPHotkey), keyEquivalent: "")
        recordOTPItem.target = self; otpHotkeySub.addItem(recordOTPItem)
        let clearOTPItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearOTPHotkey), keyEquivalent: "")
        clearOTPItem.target = self; otpHotkeySub.addItem(clearOTPItem)
        otpHotkeyItem.submenu = otpHotkeySub; m.addItem(otpHotkeyItem)

        m.addItem(.separator())

        // Codex Stats
        let codexStatsItem = NSMenuItem(title: "Codex 统计", action: #selector(showCodexStatsFromMenu), keyEquivalent: "")
        codexStatsItem.target = self; m.addItem(codexStatsItem)
        let codexStatsHotkeyItem = NSMenuItem(title: "Codex 统计快捷键", action: nil, keyEquivalent: "")
        let codexStatsHotkeySub = NSMenu()
        let curCodexCombo = codexStatsHotkeyManager?.currentCombo ?? CodexStatsHotkeyManager.defaultCombo
        let showCodexCurrent = NSMenuItem(title: "当前: \(curCodexCombo.displayString)", action: nil, keyEquivalent: "")
        showCodexCurrent.isEnabled = false; codexStatsHotkeySub.addItem(showCodexCurrent)
        codexStatsHotkeySub.addItem(.separator())
        let recordCodexItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordCodexStatsHotkey), keyEquivalent: "")
        recordCodexItem.target = self; codexStatsHotkeySub.addItem(recordCodexItem)
        let clearCodexItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearCodexStatsHotkey), keyEquivalent: "")
        clearCodexItem.target = self; codexStatsHotkeySub.addItem(clearCodexItem)
        codexStatsHotkeyItem.submenu = codexStatsHotkeySub; m.addItem(codexStatsHotkeyItem)

        m.addItem(.separator())

        // Gemini Stats
        let geminiStatsItem = NSMenuItem(title: "Antigravity 统计", action: #selector(showGeminiStatsFromMenu), keyEquivalent: "")
        geminiStatsItem.target = self; m.addItem(geminiStatsItem)
        let geminiStatsHotkeyItem = NSMenuItem(title: "Antigravity 统计快捷键", action: nil, keyEquivalent: "")
        let geminiStatsHotkeySub = NSMenu()
        let curGeminiCombo = geminiStatsHotkeyManager?.currentCombo ?? GeminiStatsHotkeyManager.defaultCombo
        let showGeminiCurrent = NSMenuItem(title: "当前: \(curGeminiCombo.displayString)", action: nil, keyEquivalent: "")
        showGeminiCurrent.isEnabled = false; geminiStatsHotkeySub.addItem(showGeminiCurrent)
        geminiStatsHotkeySub.addItem(.separator())
        let recordGeminiItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordGeminiStatsHotkey), keyEquivalent: "")
        recordGeminiItem.target = self; geminiStatsHotkeySub.addItem(recordGeminiItem)
        let clearGeminiItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearGeminiStatsHotkey), keyEquivalent: "")
        clearGeminiItem.target = self; geminiStatsHotkeySub.addItem(clearGeminiItem)
        geminiStatsHotkeyItem.submenu = geminiStatsHotkeySub; m.addItem(geminiStatsHotkeyItem)

        m.addItem(.separator())

        // WorkBuddy Stats
        let workbuddyStatsItem = NSMenuItem(title: "WorkBuddy 统计", action: #selector(showWorkBuddyStatsFromMenu), keyEquivalent: "")
        workbuddyStatsItem.target = self; m.addItem(workbuddyStatsItem)
        let workbuddyStatsHotkeyItem = NSMenuItem(title: "WorkBuddy 快捷键", action: nil, keyEquivalent: "")
        let workbuddyStatsHotkeySub = NSMenu()
        let curWorkbuddyCombo = workbuddyStatsHotkeyManager?.currentCombo ?? WorkBuddyStatsHotkeyManager.defaultCombo
        let showWorkbuddyCurrent = NSMenuItem(title: "当前: \(curWorkbuddyCombo.displayString)", action: nil, keyEquivalent: "")
        showWorkbuddyCurrent.isEnabled = false; workbuddyStatsHotkeySub.addItem(showWorkbuddyCurrent)
        workbuddyStatsHotkeySub.addItem(.separator())
        let recordWorkbuddyItem = NSMenuItem(title: "设置快捷键...", action: #selector(recordWorkBuddyStatsHotkey), keyEquivalent: "")
        recordWorkbuddyItem.target = self; workbuddyStatsHotkeySub.addItem(recordWorkbuddyItem)
        let clearWorkbuddyItem = NSMenuItem(title: "恢复默认快捷键", action: #selector(clearWorkBuddyStatsHotkey), keyEquivalent: "")
        clearWorkbuddyItem.target = self; workbuddyStatsHotkeySub.addItem(clearWorkbuddyItem)
        workbuddyStatsHotkeyItem.submenu = workbuddyStatsHotkeySub; m.addItem(workbuddyStatsHotkeyItem)

        m.addItem(.separator())

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
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; quit.keyEquivalentModifierMask = [.command]; m.addItem(quit)

        statusItem?.menu = m; statusItem?.button?.performClick(nil); statusItem?.menu = nil
    }

    @objc private func recordHotkey() {
        HotkeyRecorder.present(title: "设置快捷键") { [weak self] combo in
            self?.hotkeyManager?.save(combo: combo)
        }
    }

    @objc private func clearHotkey() {
        hotkeyManager?.clear()
    }

    @objc private func setTheme(_ s: NSMenuItem) {
        guard let t = s.representedObject as? AppTheme else { return }
        UserDefaults.standard.set(t.rawValue, forKey: "CollectionBox.theme"); applyTheme()
    }

    @objc private func openDashboard() {
        DashboardWindowController.shared.show()
    }

    @objc private func openCollection() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            edgeController?.expandAtMenuBar(buttonFrame: btnFrame)
        } else {
            edgeController?.toggle()
        }
    }

    @objc private func showOTP() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            otpController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            otpController?.showAtMouse()
        }
    }

    @objc private func showCodexStatsFromMenu() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            codexStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            codexStatsController?.showAtMouse()
        }
    }

    private func showCodexStats() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            codexStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            codexStatsController?.showAtMouse()
        }
    }

    @objc private func showGeminiStatsFromMenu() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            geminiStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            geminiStatsController?.showAtMouse()
        }
    }

    private func showGeminiStats() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            geminiStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            geminiStatsController?.showAtMouse()
        }
    }

    @objc private func showWorkBuddyStatsFromMenu() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            workbuddyStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            workbuddyStatsController?.showAtMouse()
        }
    }

    private func showWorkBuddyStats() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            workbuddyStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            workbuddyStatsController?.showAtMouse()
        }
    }

    @objc private func recordWorkBuddyStatsHotkey() {
        HotkeyRecorder.present(title: "设置 WorkBuddy 统计快捷键") { [weak self] combo in
            self?.workbuddyStatsHotkeyManager?.save(combo: combo)
        }
    }

    @objc private func clearWorkBuddyStatsHotkey() {
        workbuddyStatsHotkeyManager?.clear()
    }

    @objc private func recordOTPHotkey() {
        HotkeyRecorder.present(title: "设置 OTP 快捷键") { [weak self] combo in
            self?.otpHotkeyManager?.save(combo: combo)
        }
    }

    @objc private func clearOTPHotkey() {
        otpHotkeyManager?.clear()
    }

    @objc private func recordCodexStatsHotkey() {
        HotkeyRecorder.present(title: "设置 Codex 统计快捷键") { [weak self] combo in
            self?.codexStatsHotkeyManager?.save(combo: combo)
        }
    }

    @objc private func clearCodexStatsHotkey() {
        codexStatsHotkeyManager?.clear()
    }

    @objc private func recordGeminiStatsHotkey() {
        HotkeyRecorder.present(title: "设置 Antigravity 统计快捷键") { [weak self] combo in
            self?.geminiStatsHotkeyManager?.save(combo: combo)
        }
    }

    @objc private func clearGeminiStatsHotkey() {
        geminiStatsHotkeyManager?.clear()
    }

    @objc private func hidePanel() { edgeController?.collapse() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func applyTheme() {
        let t = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        NSApp.appearance = t.appearance
    }
}
