import AppKit
import Carbon

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
    private let otpHotkeyManager = AgentStatsHotkeyManager(
        keyPrefix: "CollectionBox.otpHotkey",
        eventID: 2,
        defaultCombo: HotkeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey)),
        label: "OTP"
    )
    private let codexStatsController = AgentStatsWindowController(agent: .codex)
    private let geminiStatsController = AgentStatsWindowController(agent: .gemini)
    private let workbuddyStatsController = AgentStatsWindowController(agent: .workbuddy)
    private let codexStatsHotkeyManager = AgentStatsHotkeyManager(
        keyPrefix: "CollectionBox.codexStatsHotkey",
        eventID: 3,
        defaultCombo: HotkeyCombo(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(cmdKey | shiftKey)),
        label: "Codex 统计"
    )
    private let geminiStatsHotkeyManager = AgentStatsHotkeyManager(
        keyPrefix: "CollectionBox.geminiStatsHotkey",
        eventID: 4,
        defaultCombo: HotkeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)),
        label: "Antigravity 统计"
    )
    private let workbuddyStatsHotkeyManager = AgentStatsHotkeyManager(
        keyPrefix: "CollectionBox.workbuddyStatsHotkey",
        eventID: 5,
        defaultCombo: HotkeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey)),
        label: "WorkBuddy 统计"
    )
    private var todoController: TodoCaptureWindowController?
    private let todoHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.todoHotkey", eventID: 9)
    private var fleetingController: FleetingCaptureWindowController?
    private let fleetingHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.fleetingHotkey", eventID: 10)
    private let clipboardStatsHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.clipboardStatsHotkey", eventID: 15)
    private let browserStatsHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.browserStatsHotkey", eventID: 16)
    private let inputStatsHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.inputStatsHotkey", eventID: 11)
    private let portManagerHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.portManagerHotkey", eventID: 12)
    private let processManagerHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.processManagerHotkey", eventID: 13)
    private let trafficHotkeyManager = AgentStatsHotkeyManager(keyPrefix: "CollectionBox.trafficHotkey", eventID: 14)
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem?.button else { return }
        if let sym = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "Pinner") {
            let config = NSImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
            let img = sym.withSymbolConfiguration(config) ?? sym
            img.isTemplate = true
            b.image = img
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyDown
        }
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.action = #selector(handleClick(_:))
        b.target = self
        edgeController = EdgeDockWindowController(store: store)
        hotkeyManager = HotkeyManager()
        hotkeyManager?.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.collection) else { return }
            self?.edgeController?.expand()
        }
        hotkeyManager?.register()

        otpController = OTPWindowController(store: otpStore)
        otpHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.otp) else { return }
            self?.otpController?.toggle(autoCopy: true)
        }
        otpHotkeyManager.register()

        codexStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.showAgentPanel(.codex)
        }
        codexStatsHotkeyManager.register()

        geminiStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.showAgentPanel(.gemini)
        }
        geminiStatsHotkeyManager.register()

        workbuddyStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.showAgentPanel(.workbuddy)
        }
        workbuddyStatsHotkeyManager.register()

        todoController = todoCaptureController()

        dashboardHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.openDashboard()
        }
        zcodeStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.showAgentPanel(.zcode)
        }
        dshStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.agentStats) else { return }
            self?.showAgentPanel(.dsh)
        }
        todoHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.todo) else { return }
            self?.showTodo()
        }
        fleetingHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.fleeting) else { return }
            self?.showFleeting()
        }
        clipboardStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.clipboardStats) else { return }
            self?.showClipboardStats()
        }
        browserStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.browserStats) else { return }
            self?.showBrowserStats()
        }
        inputStatsHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.inputStats) else { return }
            self?.showInputStats()
        }
        portManagerHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.portManager) else { return }
            self?.showPortManager()
        }
        processManagerHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.processManager) else { return }
            self?.showProcessManager()
        }
        trafficHotkeyManager.onHotkeyTriggered = { [weak self] in
            guard ModuleManager.shared.isEnabled(.traffic) else { return }
            self?.showTraffic()
        }
        dashboardHotkeyManager.register()
        zcodeStatsHotkeyManager.register()
        dshStatsHotkeyManager.register()
        todoHotkeyManager.register()
        fleetingHotkeyManager.register()
        clipboardStatsHotkeyManager.register()
        browserStatsHotkeyManager.register()
        inputStatsHotkeyManager.register()
        portManagerHotkeyManager.register()
        processManagerHotkeyManager.register()
        trafficHotkeyManager.register()

        Task { @MainActor in
            if ModuleManager.shared.isEnabled(.inputStats) {
                InputStatsService.shared.startMonitoring()
            }
            if ModuleManager.shared.isEnabled(.traffic) {
                TrafficMonitorService.shared.startMonitoring()
            }
        }

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

    /// Rebuilt on every right click so module/agent selection changes need no restart.
    public func makeMenu(
        enabledAgents: Set<StatsAgent> = StatsAgentSelection.shared.enabledAgents,
        modules: ModuleManager = .shared
    ) -> NSMenu {
        let m = NSMenu()

        // Cluster order is ModuleCluster.allCases (观测 → 录入 → 工具) and each
        // cluster's member order comes from PinnerModule.ordered(in:), which
        // keeps the drawer third in tools — below 进程, above 验证码.
        for cluster in ModuleCluster.allCases {
            let members = PinnerModule.ordered(in: cluster).filter {
                modules.isEnabled($0)
            }
            guard !members.isEmpty else { continue }

            m.addItem(.sectionHeader(title: cluster.rawValue))
            for module in members {
                addItem(for: module, to: m)
                if module == .agentStats {
                    addAgentDetails(to: m, enabledAgents: enabledAgents)
                }
            }
        }

        m.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.image = nil
        m.addItem(settingsItem)

        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Pinner", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; quit.keyEquivalentModifierMask = [.command]; m.addItem(quit)

        return m
    }

    private func addItem(for module: PinnerModule, to menu: NSMenu) {
        let item = NSMenuItem(title: module.title, action: action(for: module), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func action(for module: PinnerModule) -> Selector {
        switch module {
        case .collection: return #selector(openCollection)
        case .todo: return #selector(showTodo)
        case .fleeting: return #selector(showFleeting)
        case .otp: return #selector(showOTP)
        case .agentStats: return #selector(openDashboard)
        case .clipboardStats: return #selector(showClipboardStats)
        case .browserStats: return #selector(showBrowserStats)
        case .inputStats: return #selector(showInputStats)
        case .portManager: return #selector(showPortManager)
        case .processManager: return #selector(showProcessManager)
        case .traffic: return #selector(showTraffic)
        }
    }

    /// Drill-down from the aggregate dashboard into each enabled agent.
    private func addAgentDetails(to menu: NSMenu, enabledAgents: Set<StatsAgent>) {
        let activeAgents = StatsAgent.allCases.filter { enabledAgents.contains($0) }
        guard !activeAgents.isEmpty else { return }

        let detailsItem = NSMenuItem(title: "各 Agent 明细", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for agent in activeAgents {
            let item = NSMenuItem(title: agent.label, action: #selector(showAgentStats(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = agent; sub.addItem(item)
        }
        detailsItem.submenu = sub
        menu.addItem(detailsItem)
    }

    @objc public func openSettings() {
        SettingsWindowController.shared.show(tab: .general)
    }

    // MARK: - Hotkey Accessors for Settings

    public func dashboardHotkeyString() -> String {
        dashboardHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordDashboardHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置 Agent 总览快捷键") { [weak self] combo in
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

    public func fleetingHotkeyString() -> String {
        fleetingHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordFleetingHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置闪念投递快捷键") { [weak self] combo in
            self?.fleetingHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearFleetingHotkey() {
        fleetingHotkeyManager.clear()
    }

    public func clipboardStatsHotkeyString() -> String {
        clipboardStatsHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordClipboardStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置剪贴统计快捷键") { [weak self] combo in
            self?.clipboardStatsHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearClipboardStatsHotkey() {
        clipboardStatsHotkeyManager.clear()
    }

    public func browserStatsHotkeyString() -> String {
        browserStatsHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordBrowserStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置浏览统计快捷键") { [weak self] combo in
            self?.browserStatsHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearBrowserStatsHotkey() {
        browserStatsHotkeyManager.clear()
    }

    public func inputStatsHotkeyString() -> String {
        inputStatsHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordInputStatsHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置键鼠统计快捷键") { [weak self] combo in
            self?.inputStatsHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearInputStatsHotkey() {
        inputStatsHotkeyManager.clear()
    }

    public func portManagerHotkeyString() -> String {
        portManagerHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordPortManagerHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置端口快捷键") { [weak self] combo in
            self?.portManagerHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearPortManagerHotkey() {
        portManagerHotkeyManager.clear()
    }

    public func processManagerHotkeyString() -> String {
        processManagerHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordProcessManagerHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置进程快捷键") { [weak self] combo in
            self?.processManagerHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearProcessManagerHotkey() {
        processManagerHotkeyManager.clear()
    }

    public func trafficHotkeyString() -> String {
        trafficHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordTrafficHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置流量统计快捷键") { [weak self] combo in
            self?.trafficHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearTrafficHotkey() {
        trafficHotkeyManager.clear()
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
        otpHotkeyManager.currentCombo?.displayString ?? "未设置"
    }

    public func recordOTPHotkey(completion: (() -> Void)? = nil) {
        HotkeyRecorder.present(title: "设置验证码快捷键") { [weak self] combo in
            self?.otpHotkeyManager.save(combo: combo)
            completion?()
        }
    }

    public func clearOTPHotkey() {
        otpHotkeyManager.clear()
    }

    public func agentStatsHotkeyString(for agent: StatsAgent) -> String {
        agentStatsHotkeyManager(for: agent).currentCombo?.displayString ?? "未设置"
    }

    public func recordAgentStatsHotkey(for agent: StatsAgent, completion: (() -> Void)? = nil) {
        let manager = agentStatsHotkeyManager(for: agent)
        HotkeyRecorder.present(title: "设置 \(agent.label) 统计快捷键") { combo in
            manager.save(combo: combo)
            completion?()
        }
    }

    public func clearAgentStatsHotkey(for agent: StatsAgent) {
        agentStatsHotkeyManager(for: agent).clear()
    }

    // MARK: - Actions

    @objc private func showAgentStats(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? StatsAgent else { return }
        showAgentPanel(agent)
    }

    private func statsController(for agent: StatsAgent) -> AgentStatsWindowController {
        switch agent {
        case .codex: return codexStatsController
        case .gemini: return geminiStatsController
        case .workbuddy: return workbuddyStatsController
        case .zcode: return zcodeStatsController
        case .dsh: return dshStatsController
        }
    }

    private func showAgentPanel(_ agent: StatsAgent) {
        let controller = statsController(for: agent)
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            controller.showAtMenuBar(buttonFrame: btnFrame)
        } else {
            controller.showAtMouse()
        }
    }

    private func agentStatsHotkeyManager(for agent: StatsAgent) -> AgentStatsHotkeyManager {
        switch agent {
        case .codex: return codexStatsHotkeyManager
        case .gemini: return geminiStatsHotkeyManager
        case .workbuddy: return workbuddyStatsHotkeyManager
        case .zcode: return zcodeStatsHotkeyManager
        case .dsh: return dshStatsHotkeyManager
        }
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

    private func fleetingCaptureController() -> FleetingCaptureWindowController {
        if let fleetingController { return fleetingController }
        let controller = FleetingCaptureWindowController.shared
        fleetingController = controller
        return controller
    }

    @objc public func showFleeting() {
        if let btn = statusItem?.button {
            let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
            fleetingCaptureController().showAtMenuBar(buttonFrame: btnFrame)
        } else {
            fleetingCaptureController().showAtMouse()
        }
    }

    @objc public func showClipboardStats() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                ClipboardStatsWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                ClipboardStatsWindowController.shared.showAtMouse()
            }
        }
    }

    @objc public func showBrowserStats() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                BrowserStatsWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                BrowserStatsWindowController.shared.showAtMouse()
            }
        }
    }

    @objc public func showInputStats() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                InputStatsWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                InputStatsWindowController.shared.showAtMouse()
            }
        }
    }

    @objc public func showPortManager() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                PortManagerWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                PortManagerWindowController.shared.showAtMouse()
            }
        }
    }

    @objc public func showProcessManager() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                ProcessManagerWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                ProcessManagerWindowController.shared.showAtMouse()
            }
        }
    }

    @objc public func showTraffic() {
        Task { @MainActor in
            if let btn = self.statusItem?.button {
                let btnFrame = btn.window?.convertToScreen(btn.frame) ?? .zero
                TrafficWindowController.shared.showAtMenuBar(buttonFrame: btnFrame)
            } else {
                TrafficWindowController.shared.showAtMouse()
            }
        }
    }

    @MainActor
    @objc private func quitApp() {
        TrafficMonitorService.shared.stopMonitoring()
        NSApp.terminate(nil)
    }
    private func applyTheme() {
        let t = AppTheme(rawValue: UserDefaults.standard.integer(forKey: "CollectionBox.theme")) ?? .auto
        NSApp.appearance = t.appearance
    }
}