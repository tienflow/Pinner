import SwiftUI
import AppKit

/// Quick-capture panel: input → confirmation card → Apple Reminder.
///
/// M1 skeleton: the parse step is hardcoded (M2 swaps in TodoLLMClient);
/// the write and overview paths already hit the real EventKit service.
struct TodoCaptureView: View {
    @State private var input = ""
    @State private var card = EditableTask()
    @State private var isCardPresent = false
    @State private var lists: [String] = []
    @State private var items: [ReminderItem] = []
    @State private var authState: AuthState = .unknown
    @State private var statusText: String?
    @State private var statusIsPositive = false
    @State private var isParsing = false
    @State private var isFallbackCard = false

    private enum AuthState { case unknown, granted, denied }

    /// Fields under confirmation, all editable before saving.
    struct EditableTask {
        var title: String = ""
        var due: Date = Date()
        var hasDue: Bool = true
        var priority: Int = 0      // EK raw: 0 none / 9 low / 5 medium / 1 high
        var list: String = ""      // "" = default calendar
    }

    private let service = RemindersService.shared

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd EEE"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Pure formatter — unit-tested in M4.
    static func dueText(_ date: Date) -> String {
        "\(dayFormatter.string(from: date)) \(timeFormatter.string(from: date))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            inputSection
            if isCardPresent { confirmationCard }
            if authState == .denied { deniedRow }
            Divider()
            overviewHeader
            if items.isEmpty {
                emptyOverview
            } else {
                overviewList
            }
            if let statusText { statusBar(text: statusText) }
        }
        .frame(width: 360, height: 420)
        .task { await refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("待办").font(.system(size: 13, weight: .semibold))
            Spacer()
            if isCardPresent {
                Text("确认后按 ⏎ 保存").font(.system(size: Design.micro)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeTextField(text: $input, placeholder: "说点什么，比如\"明早交周报\"", autoFocus: true) {
                submitInput()
            }
            .frame(height: 24)
            .disabled(isParsing)
            HStack(spacing: 6) {
                if isParsing {
                    ProgressView().controlSize(.mini)
                    Text("解析中…").font(.system(size: Design.micro)).foregroundStyle(.secondary)
                } else {
                    Text("⏎ 解析并确认 · ⎋ 丢弃").font(.system(size: Design.micro)).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Confirmation Card

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isFallbackCard {
                Label("未能识别时间，已按原文保存", systemImage: "exclamationmark.circle")
                    .font(.system(size: Design.micro))
                    .foregroundStyle(.orange)
            }
            NativeTextField(text: $card.title, placeholder: "标题", autoFocus: true)
                .frame(height: 22)

            HStack(spacing: 8) {
                Toggle("到期", isOn: $card.hasDue)
                    .toggleStyle(.checkbox)
                    .font(.system(size: Design.caption))
                if card.hasDue {
                    DatePicker("", selection: $card.due, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .font(.system(size: Design.caption))
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("优先级").font(.system(size: Design.caption)).foregroundStyle(.secondary)
                Picker("", selection: $card.priority) {
                    Text("无").tag(0)
                    Text("低").tag(9)
                    Text("中").tag(5)
                    Text("高").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("列表").font(.system(size: Design.caption)).foregroundStyle(.secondary)
                Picker("", selection: $card.list) {
                    Text("默认").tag("")
                    ForEach(lists, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Button("保存") { saveCard() }
                    .keyboardShortcut(.defaultAction)
                Button("丢弃") { discardCard() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Design.radiusM).fill(Color(nsColor: .controlBackgroundColor)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Authorization

    private var deniedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                .font(.system(size: Design.caption))
            Text("未获得提醒事项访问权限").font(.system(size: Design.caption)).foregroundStyle(.secondary)
            Spacer()
            Button("打开设置") { openRemindersPrivacySettings() }
                .font(.system(size: Design.caption))
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: - Overview

    private var overviewHeader: some View {
        HStack {
            Image(systemName: "calendar.badge.clock").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("今天 · 逾期").font(.system(size: Design.ui, weight: .semibold))
            Spacer()
            Text("\(items.count)").font(.system(size: Design.caption)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var emptyOverview: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "text.badge.checkmark").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text("今天没有待办").font(.system(size: Design.caption)).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxHeight: 140)
    }

    private var overviewList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    overviewRow(item)
                    Divider()
                }
            }
        }.frame(maxHeight: 140)
    }

    private func overviewRow(_ item: ReminderItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.system(size: Design.body)).lineLimit(1)
            HStack(spacing: 4) {
                if let due = item.dueDate {
                    Text(Self.dueText(due))
                        .font(.system(size: Design.caption))
                        .foregroundStyle(item.isOverdue ? .red : .secondary)
                }
                if !item.priorityLabel.isEmpty {
                    Text(item.priorityLabel)
                        .font(.system(size: Design.micro))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                if !item.listName.isEmpty {
                    Text(item.listName).font(.system(size: Design.caption)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { openRemindersApp() }
    }

    // MARK: - Status Bar

    private func statusBar(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIsPositive ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: Design.caption))
                .foregroundStyle(statusIsPositive ? .green : .orange)
            Text(text).font(.system(size: Design.caption))
            Spacer()
            if statusIsPositive {
                Button("打开提醒事项") { openRemindersApp() }
                    .font(.system(size: Design.caption))
            }
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func showStatus(_ text: String, positive: Bool = false) {
        statusText = text
        statusIsPositive = positive
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if statusText == text { statusText = nil }
        }
    }

    // MARK: - Actions

    private func refreshAll() async {
        if await service.requestAccess() {
            authState = .granted
            lists = service.listNames()
            await reloadOverview()
        } else {
            authState = service.isAuthorized ? .granted : .denied
        }
    }

    private func reloadOverview() async {
        items = await service.fetchTodayAndOverdue()
    }

    /// Parse via the configured LLM; on timeout/network/unparseable response,
    /// fall back to a card holding the raw text (no due date), per plan R1/R3.
    private func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard authState == .granted else {
            showStatus("请先允许访问提醒事项")
            return
        }
        let store = TodoSettingsStore.shared
        guard store.isConfigured else {
            showStatus("请先配置待办 AI 设置")
            TodoSettingsWindowController.shared.show()
            return
        }
        guard !isParsing else { return } // 防重入

        let config = store.config
        isParsing = true
        Task {
            defer { isParsing = false }
            let client = TodoLLMClient()
            let context = TodoPromptContext(
                input: text, now: Date(),
                lists: lists, lastList: UserDefaults.standard.string(forKey: "CollectionBox.todo.lastList")
            )
            let result: ParsedTask?
            do {
                result = try await client.parse(context: context, config: config)
            } catch {
                result = nil
            }
            if let result, !result.title.isEmpty {
                card = EditableTask(
                    title: result.title,
                    due: result.due ?? Date(),
                    hasDue: result.due != nil,
                    priority: result.priority,
                    list: result.list ?? ""
                )
                isFallbackCard = result.fallback
                isCardPresent = true
            } else {
                // 降级：原文直接作为标题，无到期日
                card = EditableTask(title: text, due: Date(), hasDue: false, priority: 0, list: "")
                isFallbackCard = true
                isCardPresent = true
            }
        }
    }

    private func saveCard() {
        let trimmed = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showStatus("标题不能为空")
            return
        }
        do {
            try service.createTask(
                title: trimmed,
                due: card.hasDue ? card.due : nil,
                priority: card.priority,
                list: card.list.isEmpty ? nil : card.list
            )
        } catch {
            showStatus(error.localizedDescription)
            return
        }
        if !card.list.isEmpty {
            UserDefaults.standard.set(card.list, forKey: "CollectionBox.todo.lastList")
        }
        discardCard()
        input = ""
        if isFallbackCard {
            showStatus("已添加（未能解析时间）", positive: true)
        } else {
            showStatus("已添加", positive: true)
        }
        isFallbackCard = false
        Task { await reloadOverview() }
    }

    private func discardCard() {
        isCardPresent = false
        card = EditableTask()
    }

    private func openRemindersApp() {
        // x-apple-reminders:// is not a registered scheme on current macOS;
        // resolve the app via its bundle ID instead.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openRemindersPrivacySettings() {
        if let url = URL(string: "x-apple-prefs:com.apple.preference.security?Privacy_Reminders"),
           NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
