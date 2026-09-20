import AppKit
import ServiceManagement

enum AppTheme: Int, CaseIterable, Identifiable {
    case auto = 0, light = 1, dark = 2
    var id: Int { rawValue }
    var label: String { ["自动","浅色","深色"][Self.allCases.firstIndex(of: self)!] }
    var appearance: NSAppearance? {
        switch self { case .auto: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

public final class MenuBarController: NSObject {
    public static weak var shared: MenuBarController?

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
    private var todoController: TodoCaptureWindowController?
    private let todoHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.todoHotkey", eventID: 9)
    private let zcodeStatsController = AgentStatsWindowController(agent: .zcode)
    private let dshStatsController = AgentStatsWindowController(agent: .dsh)
    private let zcodeStatsHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.zcodeStatsHotkey", eventID: 6)
    private let dshStatsHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.dshStatsHotkey", eventID: 7)
    private let dashboardHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.dashboardHotkey", eventID: 8)

    public init(store: CollectionStore) {
        self.store = store
        super.init()
        Self.shared = self
    }

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

        todoController = todoCaptureController()

        dashboardHotkeyManager.onHotkeyTriggered = { [weak self] in self?.openDashboard() }
        zcodeStatsHotkeyManager.onHotkeyTriggered = { [weak self] in self?.showAgentPanel(.zcode) }
        dshStatsHotkeyManager.onHotkeyTriggered = { [weak self] in self?.showAgentPanel(.dsh) }
        todoHotkeyManager.onHotkeyTriggered = { [weak self] in self?.showTodo() }
        dashboardHotkeyManager.register()
        zcodeStatsHotkeyManager.register()
        dshStatsHotkeyManager.register()
        todoHotkeyManager.register()

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
        statusItem?.menu = makeMenu()
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Rebuilt on every right click so dashboard selection changes need no restart.
    public func makeMenu(enabledAgents: Set<StatsAgent> = StatsAgentSelection.shared.enabledAgents) -> NSMenu {
        let m = NSMenu()
        let header = NSMenuItem(title: "总览", action: #selector(openDashboard), keyEquivalent: "")
        header.target = self; m.addItem(header)
        m.addItem(.separator())

        // 待办 quick capture
        let todoItem = NSMenuItem(title: "待办", action: #selector(showTodo), keyEquivalent: "")
        todoItem.target = self; m.addItem(todoItem)

        // Collection
        let collectionItem = NSMenuItem(title: "收藏夹", action: #selector(openCollection), keyEquivalent: "")
        collectionItem.target = self; m.addItem(collectionItem)

        // OTP
        let otpItem = NSMenuItem(title: "OTP 验证码", action: #selector(showOTP), keyEquivalent: "")
        otpItem.target = self; m.addItem(otpItem)

        m.addItem(.separator())

        // Agent stats entries follow the dashboard selection.
        for agent in StatsAgent.allCases where enabledAgents.contains(agent) {
            let item = NSMenuItem(title: "\(agent.label) 统计", action: #selector(showAgentStats(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = agent; m.addItem(item)
        }

        m.addItem(.separator())

        // Unified Preferences / Settings
        let settingsItem = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        m.addItem(settingsItem)

        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Pinner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; quit.keyEquivalentModifierMask = [.command]; m.addItem(quit)

        return m
    }

    @objc public func openSettings() {
        SettingsWindowController.shared.show(tab: .general)
    }

    // MARK: - Hotkey Accessors for Settings

    public func dashboardHotkeyString() -> String {
        dashboardHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordDashboardHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置总览快捷键") { [weak self] combo in
            self?.dashboardHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearDashboardHotkey() {
        dashboardHotkeyManager.clear()
    }

    public func todoHotkeyString() -> String {
        todoHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordTodoHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置待办快捷键") { [weak self] combo in
            self?.todoHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearTodoHotkey() {
        todoHotkeyManager.clear()
    }

    public func collectionHotkeyString() -> String {
        (hotkeyManager?.currentCombo ?? HotkeyManager.defaultCombo).displayString
    }

    public func recordHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置收藏夹快捷键") { [weak self] combo in
            self?.hotkeyManager?.save(combo: combo)
            completion?()
        }
    }

    public func clearHotkey() {
        hotkeyManager?.clear()
    }

    public func otpHotkeyString() -> String {
        (otpHotkeyManager?.currentCombo ?? OTPHotkeyManager.defaultCombo).displayString
    }

    public func recordOTPHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置 OTP 快捷键") { [weak self] combo in
            self?.otpHotkeyManager?.save(combo: combo)
            completion?()
        }
    }

    public func clearOTPHotkey() {
        otpHotkeyManager?.clear()
    }

    public func codexHotkeyString() -> String {
        (codexStatsHotkeyManager?.currentCombo ?? CodexStatsHotkeyManager.defaultCombo).displayString
    }

    public func recordCodexStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置 Codex 统计快捷键") { [weak self] combo in
            self?.codexStatsHotkeyManager?.save(combo: combo)
            completion?()
        }
    }

    public func clearCodexStatsHotkey() {
        codexStatsHotkeyManager?.clear()
    }

    public func geminiHotkeyString() -> String {
        (geminiStatsHotkeyManager?.currentCombo ?? GeminiStatsHotkeyManager.defaultCombo).displayString
    }

    public func recordGeminiStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置 Gemini 统计快捷键") { [weak self] combo in
            self?.geminiStatsHotkeyManager?.save(combo: combo)
            completion?()
        }
    }

    public func clearGeminiStatsHotkey() {
        geminiStatsHotkeyManager?.clear()
    }

    public func workbuddyHotkeyString() -> String {
        (workbuddyStatsHotkeyManager?.currentCombo ?? WorkBuddyStatsHotkeyManager.defaultCombo).displayString
    }

    public func recordWorkBuddyStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置 WorkBuddy 统计快捷键") { [weak self] combo in
            self?.workbuddyStatsHotkeyManager?.save(combo: combo)
            completion?()
        }
    }

    public func clearWorkBuddyStatsHotkey() {
        workbuddyStatsHotkeyManager?.clear()
    }

    public func dshHotkeyString() -> String {
        dshStatsHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordAgentStatsHotkey(for agent: StatsAgent, completion: (() -> Void)? = nil) {
        guard let manager = genericAgentStatsHotkeyManager(agent) else { return }
        HotkeyRecorder.present(title: "设置 \(agent.label) 统计快捷键") { combo in
            manager.save(combo: combo)
            completion?()
        }
    }

    public func clearAgentStatsHotkey(for agent: StatsAgent) {
        genericAgentStatsHotkeyManager(agent)?.clear()
    }

    // MARK: - Actions

    @objc private func showAgentStats(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? StatsAgent else { return }
        showAgentPanel(agent)
    }

    /// Mirrors the dashboard's Agent toggle, including the keep-last-on rule.
    @objc private func toggleAgentStats(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? StatsAgent else { return }
        let selection = StatsAgentSelection.shared
        let isOn = selection.enabledAgents.contains(agent)
        if isOn && selection.enabledAgents.count <= 1 { return }
        selection.setEnabled(agent, to: !isOn)
    }

    /// Codex / Antigravity / WorkBuddy keep their dedicated panels; ZCode and
    /// DSH open the shared compact panel.
    private func showAgentPanel(_ agent: StatsAgent) {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            switch agent {
            case .codex: codexStatsController?.showAtMenuBar(buttonFrame: btnFrame)
            case .gemini: geminiStatsController?.showAtMenuBar(buttonFrame: btnFrame)
            case .workbuddy: workbuddyStatsController?.showAtMenuBar(buttonFrame: btnFrame)
            case .zcode: zcodeStatsController.showAtMenuBar(buttonFrame: btnFrame)
            case .dsh: dshStatsController.showAtMenuBar(buttonFrame: btnFrame)
            }
        } else {
            switch agent {
            case .codex: codexStatsController?.showAtMouse()
            case .gemini: geminiStatsController?.showAtMouse()
            case .workbuddy: workbuddyStatsController?.showAtMouse()
            case .zcode: zcodeStatsController.showAtMouse()
            case .dsh: dshStatsController.showAtMouse()
            }
        }
    }

    /// ZCode / DSH share the generic hotkey manager; other agents have none.
    private func genericAgentStatsHotkeyManager(_ agent: StatsAgent) -> AgentStatsHotkeyManager? {
        switch agent {
        case .zcode: return zcodeStatsHotkeyManager
        case .dsh: return dshStatsHotkeyManager
        default: return nil
        }
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

    /// Lazily created so the runner/test path can also fire the action.
    private func todoCaptureController() -> TodoCaptureWindowController {
        if let todoController { return todoController }
        let controller = TodoCaptureWindowController()
        todoController = controller
        return controller
    }

    @objc private func showTodo() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            todoCaptureController().showAtMenuBar(buttonFrame: btnFrame)
        } else {
            todoCaptureController().showAtMouse()
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

    private func showGeminiStats() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            geminiStatsController?.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            geminiStatsController?.showAtMouse()
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

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = sender.state == .off
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enable ? "无法开启开机自启" : "无法关闭开机自启"
            alert.informativeText = enable
                ? "请将 Pinner 放入「应用程序」文件夹后重试。\n\(error.localizedDescription)"
                : error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func hidePanel() { edgeController?.collapse() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func applyTheme() {
        let t = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        NSApp.appearance = t.appearance
    }
}