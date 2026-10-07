import SwiftUI
import AppKit
import ServiceManagement

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case modules = "功能模块"
    case hotkeys = "快捷键"
    case aiConfig = "AI 配置"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .modules: return "square.grid.2x2"
        case .hotkeys: return "keyboard"
        case .aiConfig: return "sparkles"
        }
    }
}

public struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @ObservedObject private var moduleManager = ModuleManager.shared
    @ObservedObject private var agentSelection = StatsAgentSelection.shared
    @ObservedObject private var inputStatsService = InputStatsService.shared
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var currentTheme: Int = UserDefaults.standard.integer(forKey: "CollectionBox.theme")
    @State private var hotkeyRefreshID = UUID()

    @AppStorage("CollectionBox.shelfTrashOriginalOnDragOut")
    private var shelfTrashOriginalOnDragOut: Bool = false

    public init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Unified Titlebar & Tab Header
            HStack(spacing: 0) {
                Spacer().frame(width: 32)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        tabButton(for: tab)
                    }
                }
                Spacer()
                PanelCloseButton(helpText: "关闭设置 (⌘W)") {
                    NSApp.keyWindow?.close()
                }
                .frame(width: 32, alignment: .trailing)
            }
            .frame(height: 52)
            .padding(.horizontal, 14)

            Divider().opacity(0.35)

            // Content Area
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .modules:
                    modulesTab
                case .hotkeys:
                    hotkeysTab
                case .aiConfig:
                    aiConfigTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlassBackground(cornerRadius: 16)
        .ignoresSafeArea()
    }

    // MARK: - Tab Selector Button

    private func tabButton(for tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(NSColor.selectedControlColor).opacity(0.18) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 1: General

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section: Launch
                sectionCard(title: "启动设置", icon: "bolt") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开机自动启动")
                                .font(.system(size: 13, weight: .medium))
                            Text("系统登录时自动在后台启动 Pinner 菜单栏")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $launchAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { newValue in
                                toggleLaunchAtLogin(newValue)
                            }
                    }
                }

                // Section: Drop Shelf Physical Move
                sectionCard(title: "临时中转架", icon: "shippingbox") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("拖出后将源文件移至废纸篓（物理剪切）")
                                .font(.system(size: 13, weight: .medium))
                            Text("从暂存架拖出文件后，自动将源文件移入废纸篓并移出暂存架，实现物理剪切；可在废纸篓中随时放回")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $shelfTrashOriginalOnDragOut)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                // Section: Appearance
                sectionCard(title: "外观主题", icon: "paintpalette") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择应用界面显示风格：")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Picker("主题", selection: $currentTheme) {
                            Text("跟随系统").tag(0)
                            Text("浅色模式").tag(1)
                            Text("深色模式").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: currentTheme) { val in
                            UserDefaults.standard.set(val, forKey: "CollectionBox.theme")
                            let theme = AppTheme(rawValue: val) ?? .auto
                            NSApp.appearance = theme.appearance
                        }
                    }
                }

            }
            .padding(20)
        }
    }

    // MARK: - Tab 2: Feature Modules

    private var modulesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section 1: 工作台与捕获
                sectionCard(title: ModuleCluster.captureAndWorkspace.rawValue, icon: ModuleCluster.captureAndWorkspace.icon) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(ModuleCluster.captureAndWorkspace.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        // Collection (Core)
                        moduleRow(
                            module: .collection,
                            isCore: true,
                            isOn: .constant(true)
                        )

                        Divider()

                        // Todo
                        moduleRow(
                            module: .todo,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.todo) },
                                set: { moduleManager.setEnabled(.todo, to: $0) }
                            )
                        )

                        Divider()

                        // Fleeting
                        moduleRow(
                            module: .fleeting,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.fleeting) },
                                set: { moduleManager.setEnabled(.fleeting, to: $0) }
                            )
                        )
                    }
                }

                // Section 2: 数字监控与工具
                sectionCard(title: ModuleCluster.monitoringAndTools.rawValue, icon: ModuleCluster.monitoringAndTools.icon) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(ModuleCluster.monitoringAndTools.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        // Agent Stats
                        moduleRow(
                            module: .agentStats,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.agentStats) },
                                set: { moduleManager.setEnabled(.agentStats, to: $0) }
                            )
                        )

                        if moduleManager.isEnabled(.agentStats) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("参与统计的 Agent（至少保留一项）：")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                    ForEach(StatsAgent.allCases, id: \.self) { agent in
                                        let isEnabled = agentSelection.enabledAgents.contains(agent)
                                        Toggle(isOn: Binding(
                                            get: { isEnabled },
                                            set: { turnOn in
                                                if !turnOn && agentSelection.enabledAgents.count <= 1 { return }
                                                agentSelection.setEnabled(agent, to: turnOn)
                                            }
                                        )) {
                                            HStack(spacing: 6) {
                                                Image(systemName: agent.symbolName)
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                Text(agent.label)
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                            .padding(.leading, 30)
                            .padding(.vertical, 4)
                        }

                        Divider()

                        // Input Stats
                        moduleRow(
                            module: .inputStats,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.inputStats) },
                                set: { moduleManager.setEnabled(.inputStats, to: $0) }
                            )
                        )

                        if moduleManager.isEnabled(.inputStats) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(inputStatsService.hasAccessibilityPermission ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(inputStatsService.hasAccessibilityPermission ? "全局辅助功能权限已授予" : "未授予辅助功能权限，无法捕获全局击键")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if !inputStatsService.hasAccessibilityPermission {
                                    Button("去授权") {
                                        inputStatsService.requestAccessibility()
                                        inputStatsService.openAccessibilityPreferences()
                                    }
                                    .font(.system(size: 11))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.leading, 30)
                        }

                        Divider()

                        // Port Manager
                        moduleRow(
                            module: .portManager,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.portManager) },
                                set: { moduleManager.setEnabled(.portManager, to: $0) }
                            )
                        )

                        Divider()

                        // Process Manager
                        moduleRow(
                            module: .processManager,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.processManager) },
                                set: { moduleManager.setEnabled(.processManager, to: $0) }
                            )
                        )

                        Divider()

                        // OTP
                        moduleRow(
                            module: .otp,
                            isCore: false,
                            isOn: Binding(
                                get: { moduleManager.isEnabled(.otp) },
                                set: { moduleManager.setEnabled(.otp, to: $0) }
                            )
                        )
                    }
                }
            }
            .padding(20)
        }
    }

    private func moduleRow(module: PinnerModule, isCore: Bool, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: module.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(module.title)
                        .font(.system(size: 13, weight: .medium))
                    if isCore {
                        Text("核心基础")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .foregroundColor(.accentColor)
                    }
                }
                Text(module.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isCore {
                Toggle("", isOn: .constant(true))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(true)
            } else {
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Tab 2: Hotkeys

    private var hotkeysTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section: Core Features
                sectionCard(title: "核心功能快捷键", icon: "command") {
                    VStack(spacing: 8) {
                        hotkeyRow(
                            title: "Agent 总览看板",
                            icon: "square.grid.2x2",
                            getCombo: { MenuBarController.shared?.dashboardHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordDashboardHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearDashboardHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "待办快速录入",
                            icon: "checklist",
                            getCombo: { MenuBarController.shared?.todoHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordTodoHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearTodoHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "闪念投递",
                            icon: "note.text.badge.plus",
                            getCombo: { MenuBarController.shared?.fleetingHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordFleetingHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearFleetingHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "收藏夹抽屉",
                            icon: "tray.full",
                            getCombo: { MenuBarController.shared?.collectionHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "OTP 验证码面板",
                            icon: "key.fill",
                            getCombo: { MenuBarController.shared?.otpHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordOTPHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearOTPHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "键鼠统计面板",
                            icon: "keyboard.fill",
                            getCombo: { MenuBarController.shared?.inputStatsHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordInputStatsHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearInputStatsHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "端口管家面板",
                            icon: "network",
                            getCombo: { MenuBarController.shared?.portManagerHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordPortManagerHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearPortManagerHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "进程管家面板",
                            icon: "speedometer",
                            getCombo: { MenuBarController.shared?.processManagerHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordProcessManagerHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearProcessManagerHotkey(); hotkeyRefreshID = UUID() }
                        )
                    }
                }

                // Section: Stats Features
                sectionCard(title: "Agent 统计快捷键", icon: "waveform.path.ecg") {
                    VStack(spacing: 8) {
                        hotkeyRow(
                            title: "Codex 统计",
                            icon: "terminal.fill",
                            getCombo: { MenuBarController.shared?.codexHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordCodexStatsHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearCodexStatsHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "Antigravity 统计",
                            icon: "sparkles",
                            getCombo: { MenuBarController.shared?.geminiHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordGeminiStatsHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearGeminiStatsHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "WorkBuddy 统计",
                            icon: "briefcase.fill",
                            getCombo: { MenuBarController.shared?.workbuddyHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordWorkBuddyStatsHotkey { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearWorkBuddyStatsHotkey(); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "ZCode 统计",
                            icon: "chevron.left.forwardslash.chevron.right",
                            getCombo: { MenuBarController.shared?.zcodeHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordAgentStatsHotkey(for: .zcode) { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearAgentStatsHotkey(for: .zcode); hotkeyRefreshID = UUID() }
                        )
                        Divider()
                        hotkeyRow(
                            title: "DSH 统计",
                            icon: "fish.fill",
                            getCombo: { MenuBarController.shared?.dshHotkeyString() ?? "未设置" },
                            onRecord: { MenuBarController.shared?.recordAgentStatsHotkey(for: .dsh) { hotkeyRefreshID = UUID() } },
                            onReset: { MenuBarController.shared?.clearAgentStatsHotkey(for: .dsh); hotkeyRefreshID = UUID() }
                        )
                    }
                }
            }
            .padding(20)
            .id(hotkeyRefreshID)
        }
    }

    private func hotkeyRow(
        title: String,
        icon: String,
        getCombo: () -> String,
        onRecord: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 13, weight: .regular))

            Spacer()

            let combo = getCombo()
            Text(combo)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(combo == "未设置" ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.15))
                )
                .foregroundColor(combo == "未设置" ? .secondary : .primary)

            Button("录制") {
                onRecord()
            }
            .controlSize(.small)

            Button("恢复默认") {
                onReset()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tab 3: AI Config
 
    @AppStorage("CollectionBox.todoSnoozeHour") private var todoSnoozeHour: Int = 9
    @AppStorage("CollectionBox.todoSnoozeMinute") private var todoSnoozeMinute: Int = 0

    private var aiConfigTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionCard(title: "Jev 语义路由 (闪念投递)", icon: "arrow.triangle.branch") {
                    JevSettingsView()
                }

                sectionCard(title: "通用模型服务 (OpenAI 兼容端点)", icon: "sparkles") {
                    TodoSettingsView()
                }

                sectionCard(title: "待办偏好", icon: "clock.arrow.circlepath") {
                    todoBehaviorSection
                }
            }
            .padding(20)
        }
    }

    private var todoBehaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("一键推迟默认时刻")
                        .font(.system(size: 13, weight: .regular))
                    Text("悬浮时钟按钮与 ⌘T 快捷键推迟到明天的具体时刻")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                DatePicker(
                    "",
                    selection: Binding<Date>(
                        get: {
                            let cal = Calendar.current
                            var comps = cal.dateComponents([.year, .month, .day], from: Date())
                            comps.hour = todoSnoozeHour
                            comps.minute = todoSnoozeMinute
                            return cal.date(from: comps) ?? Date()
                        },
                        set: { newDate in
                            let cal = Calendar.current
                            let comps = cal.dateComponents([.hour, .minute], from: newDate)
                            todoSnoozeHour = comps.hour ?? 9
                            todoSnoozeMinute = comps.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .frame(width: 85)
            }
        }
    }

    // MARK: - UI Helpers

    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }
}
