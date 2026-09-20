import SwiftUI
import AppKit
import ServiceManagement

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case hotkeys = "快捷键"
    case todoAI = "待办 AI"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .todoAI: return "sparkles"
        }
    }
}

public struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @ObservedObject private var agentSelection = StatsAgentSelection.shared
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var currentTheme: Int = UserDefaults.standard.integer(forKey: "CollectionBox.theme")
    @State private var hotkeyRefreshID = UUID()

    public init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Tab Header
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(for: tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            // Content Area
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .hotkeys:
                    hotkeysTab
                case .todoAI:
                    todoAITab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 520, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Tab Selector Button

    private func tabButton(for tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 14)
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
            VStack(alignment: .leading, spacing: 20) {
                // Section: System & Launch
                sectionCard(title: "系统与启动", icon: "power") {
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

                // Section: Agent Modules
                sectionCard(title: "参与统计的 Agent", icon: "chart.bar.xaxis") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("勾选在总览看板和状态栏中展示的 Agent（至少保留一项）：")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
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
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                        Text(agent.label)
                                            .font(.system(size: 13))
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            .padding(20)
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
                            title: "总览看板",
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
                            title: "Gemini 统计",
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

    // MARK: - Tab 3: Todo AI

    private var todoAITab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodoSettingsView()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
