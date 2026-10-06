import SwiftUI
import AppKit

/// Quick-capture panel: input → confirmation card → Apple Reminder.
///
/// M1 skeleton: the parse step is hardcoded (M2 swaps in TodoLLMClient);
/// the write and overview paths already hit the real EventKit service.
struct TodoCaptureView: View {
    @State private var input = ""
    @State private var inputHeight: CGFloat = 30
    @State private var card = EditableTask()
    @State private var isCardPresent = false
    @State private var lists: [String] = []
    @State private var items: [ReminderItem] = []
    @State private var authState: AuthState = .unknown
    @State private var statusText: String?
    @State private var statusIsPositive = false
    @State private var isParsing = false
    @State private var isFallbackCard = false
    @State private var completingIds: Set<String> = []
    @State private var hoveredItemId: String?
    @State private var undoAction: TodoUndoAction?
    @State private var batchCards: [EditableTask] = []
    @State private var isBatchPresent = false
    @State private var completedTodayItems: [ReminderItem] = []
    @State private var isCompletedExpanded = false
    @AppStorage("CollectionBox.todoSnoozeHour") private var snoozeHour = 9
    @AppStorage("CollectionBox.todoSnoozeMinute") private var snoozeMinute = 0

    private enum TodoUndoAction {
        case completed(item: ReminderItem)
        case deleted(item: ReminderItem)
    }

    private enum AuthState { case unknown, granted, denied }

    /// Fields under confirmation, all editable before saving.
    struct EditableTask: Identifiable {
        var id = UUID()
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
            Divider().opacity(0.35)
            inputSection
            if isCardPresent { confirmationCard }
            if isBatchPresent { batchConfirmationCard }
            if authState == .denied { deniedRow }
            Divider().opacity(0.35)
            overviewHeader
            if items.isEmpty {
                emptyOverview
            } else {
                overviewList
            }
            if !completedTodayItems.isEmpty {
                completedSection
            }
            Spacer(minLength: 0)
            if let statusText { statusBar(text: statusText) }
        }
        // Flexible root (same as OTPView): the panel's hosting view is 28pt
        // taller than the content rect because of fullSizeContentView, so a
        // fixed frame here would float centered under the titlebar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .task { await refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            Task { await reloadOverview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reloadOverview() }
        }
        .background(
            Button("") {
                performUndo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("待办").font(.system(size: 13, weight: .semibold))

            let completed = completedTodayItems.count
            let total = completed + items.count
            if total > 0 {
                let isAllDone = completed == total
                HStack(spacing: 4) {
                    Image(systemName: isAllDone ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isAllDone ? Color.green : Color.secondary)
                    Text("今日 \(completed)/\(total)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isAllDone ? Color.green.opacity(0.16) : Color.secondary.opacity(0.10))
                )
                .overlay(
                    Capsule().strokeBorder(isAllDone ? Color.green.opacity(0.45) : Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
            }

            Spacer()
            if isCardPresent {
                Text("确认后按 ⏎ 保存").font(.system(size: Design.micro)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            AutoGrowingTextView(
                text: $input,
                height: $inputHeight,
                placeholder: "输入待办，支持识别时间、优先级与列表…",
                minHeight: 30,
                maxHeight: 100,
                autoFocus: true
            ) {
                submitInput()
            }
            .frame(height: inputHeight)
            .liquidGlassCard(cornerRadius: Design.radiusM)
            .disabled(isParsing)
            HStack(spacing: 6) {
                if isParsing {
                    ProgressView().controlSize(.mini)
                    Text("解析中…").font(.system(size: Design.micro)).foregroundStyle(.secondary)
                } else {
                    Text("⏎ 解析并确认（Shift+⏎ 换行） · ⎋ 丢弃").font(.system(size: Design.micro)).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Confirmation Card

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isFallbackCard {
                Label(fallbackReason ?? "未能识别时间，已按原文保存", systemImage: "exclamationmark.circle")
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
        .liquidGlassCard(cornerRadius: Design.radiusM)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var batchConfirmationCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("批量识别 (\(batchCards.count) 项)", systemImage: "list.bullet.rectangle")
                    .font(.system(size: Design.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button("全部保存") { saveBatchCards() }
                    .keyboardShortcut(.defaultAction)
                Button("丢弃") { discardBatchCards() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach($batchCards) { $item in
                        HStack(spacing: 6) {
                            NativeTextField(text: $item.title, placeholder: "任务标题")
                                .frame(height: 20)
                            if item.hasDue {
                                Text(Self.dueText(item.due))
                                    .font(.system(size: Design.micro))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                            if !item.list.isEmpty {
                                Text(item.list)
                                    .font(.system(size: Design.micro))
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                if let idx = batchCards.firstIndex(where: { $0.id == item.id }) {
                                    batchCards.remove(at: idx)
                                    if batchCards.isEmpty {
                                        discardBatchCards()
                                    }
                                }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("移除此项")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(10)
        .liquidGlassCard(cornerRadius: Design.radiusM)
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

    @State private var isRefreshing = false

    private var overviewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("今天 · 逾期").font(.system(size: Design.ui, weight: .semibold))
            Spacer()
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    defer { isRefreshing = false }
                    await reloadOverview()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .help("刷新提醒事项")

            Button {
                TodoSettingsWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("待办偏好与 AI 设置")

            Text("\(items.count)").font(.system(size: Design.caption)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var emptyOverview: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.badge.checkmark").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("今天没有待办").font(.system(size: Design.caption)).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxHeight: isCardPresent ? 130 : 220)
    }

    private var overdueItems: [ReminderItem] {
        items.filter { $0.isOverdue }
    }

    private var todayItems: [ReminderItem] {
        items.filter { $0.dueDate != nil && !$0.isOverdue }
    }

    private var undatedItems: [ReminderItem] {
        items.filter { $0.dueDate == nil }
    }

    private func sectionHeader(title: String, count: Int, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(color.opacity(0.08))
    }

    private var overviewList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !overdueItems.isEmpty {
                    sectionHeader(title: "已逾期", count: overdueItems.count, systemImage: "exclamationmark.circle.fill", color: .red)
                    ForEach(overdueItems) { item in
                        overviewRow(item)
                        Divider().opacity(0.35)
                    }
                }

                if !todayItems.isEmpty {
                    if !overdueItems.isEmpty || !undatedItems.isEmpty {
                        sectionHeader(title: "今天到期", count: todayItems.count, systemImage: "sun.max.fill", color: .orange)
                    }
                    ForEach(todayItems) { item in
                        overviewRow(item)
                        Divider().opacity(0.35)
                    }
                }

                if !undatedItems.isEmpty {
                    sectionHeader(title: "随时 · 无到期日", count: undatedItems.count, systemImage: "tray.fill", color: .secondary)
                    ForEach(undatedItems) { item in
                        overviewRow(item)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .frame(maxHeight: isCardPresent || isBatchPresent ? 130 : 250)
    }

    private var completedSection: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCompletedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCompletedExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("今日已完成 · \(completedTodayItems.count)")
                            .font(.system(size: Design.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    copyCompletedSummary()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("复制今日总结")
                            .font(.system(size: Design.micro))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("将今日已完成任务复制为 Markdown 格式")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            if isCompletedExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(completedTodayItems) { item in
                            completedRow(item)
                            Divider().opacity(0.35)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
    }

    private func completedRow(_ item: ReminderItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                uncompleteTask(item)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("反选恢复为未完成")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: Design.body))
                    .lineLimit(1)
                    .strikethrough(true, color: .secondary)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let doneDate = item.completionDate {
                Text(Self.timeFormatter.string(from: doneDate))
                    .font(.system(size: Design.micro))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func uncompleteTask(_ item: ReminderItem) {
        do {
            try service.setTaskCompleted(id: item.id, completed: false)
            Haptics.light()
            withAnimation(.easeOut(duration: 0.2)) {
                completedTodayItems.removeAll { $0.id == item.id }
            }
            showStatus("已恢复至未完成：\(item.title)", positive: true)
            Task { await reloadOverview() }
        } catch {
            showStatus("操作失败：\(error.localizedDescription)")
        }
    }

    private func copyCompletedSummary() {
        guard !completedTodayItems.isEmpty else {
            showStatus("暂无已完成待办可复制")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: Date())
        var md = "### 今日工作总结 (\(dateStr))\n"
        for item in completedTodayItems {
            let timeStr = item.completionDate.map { " (\(Self.timeFormatter.string(from: $0)))" } ?? ""
            md += "- [x] \(item.title)\(timeStr)\n"
        }
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.setString(md, forType: .string)
        Haptics.success()
        showStatus("已复制 \(completedTodayItems.count) 条今日总结到剪贴板", positive: true)
    }

    private func toggleComplete(_ item: ReminderItem) {
        guard !completingIds.contains(item.id) else { return }
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.15)) {
            _ = completingIds.insert(item.id)
        }
        Task {
            do {
                try service.setTaskCompleted(id: item.id, completed: true)
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    items.removeAll { $0.id == item.id }
                    completingIds.remove(item.id)
                    if hoveredItemId == item.id {
                        hoveredItemId = nil
                    }
                }
                undoAction = .completed(item: item)
                showStatus("已完成：\(item.title)", positive: true)
            } catch {
                _ = withAnimation {
                    completingIds.remove(item.id)
                }
                showStatus("标记完成失败：\(error.localizedDescription)")
            }
        }
    }

    private func overviewRow(_ item: ReminderItem) -> some View {
        let isDone = completingIds.contains(item.id)
        let isHovered = hoveredItemId == item.id
        return HStack(alignment: .center, spacing: 8) {
            Button {
                toggleComplete(item)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: Design.body))
                    .lineLimit(1)
                    .strikethrough(isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                HStack(spacing: 4) {
                    if let due = item.dueDate {
                        Text(Self.dueText(due))
                            .font(.system(size: Design.caption))
                            .foregroundStyle(item.isOverdue ? .red : .secondary)
                    }
                    if !item.priorityLabel.isEmpty {
                        Text(item.priorityLabel)
                            .font(.system(size: Design.micro, weight: item.isHighPriority ? .semibold : .regular))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(priorityBgColor(for: item)))
                            .foregroundStyle(priorityTextColor(for: item))
                    }
                    if !item.listName.isEmpty {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(listColor(for: item))
                                .frame(width: 5, height: 5)
                            Text(item.listName).font(.system(size: Design.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                .opacity(isDone ? 0.5 : 1.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { openRemindersApp() }

            if isHovered && !isDone {
                HStack(spacing: 6) {
                    TodoHoverSnoozeButton(timeText: snoozeTimeDescription) {
                        snoozeTask(item, to: tomorrowDate)
                    }
                    TodoHoverDeleteButton {
                        deleteTask(item)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusS)
                .fill(isHovered ? Color(nsColor: .quaternaryLabelColor).opacity(0.4) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                if hovering {
                    hoveredItemId = item.id
                } else if hoveredItemId == item.id {
                    hoveredItemId = nil
                }
            }
        }
        .contextMenu {
            Button {
                snoozeTask(item, to: tomorrowDate)
            } label: {
                Label("推迟到明天 (\(snoozeTimeDescription))", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("t", modifiers: .command)

            Button {
                snoozeTask(item, to: nextWeekDate)
            } label: {
                Label("推迟到下周一 (\(snoozeTimeDescription))", systemImage: "calendar.badge.clock")
            }
            .keyboardShortcut("m", modifiers: .command)

            if item.dueDate != nil {
                Button {
                    snoozeTask(item, to: nil)
                } label: {
                    Label("清除到期时间", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button {
                openRemindersApp()
            } label: {
                Label("在提醒事项中打开", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()
            Button(role: .destructive) {
                deleteTask(item)
            } label: {
                Label("删除待办", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func snoozeTask(_ item: ReminderItem, to date: Date?) {
        do {
            try service.updateTaskDueDate(id: item.id, newDue: date)
            Haptics.light()
            showStatus(date != nil ? "已推迟：\(item.title)" : "已清除到期时间", positive: true)
            Task { await reloadOverview() }
        } catch {
            showStatus("推迟失败：\(error.localizedDescription)")
        }
    }

    private func deleteTask(_ item: ReminderItem) {
        do {
            try service.deleteTask(id: item.id)
            Haptics.levelChange()
            withAnimation(.easeOut(duration: 0.2)) {
                items.removeAll { $0.id == item.id }
                if hoveredItemId == item.id {
                    hoveredItemId = nil
                }
            }
            undoAction = .deleted(item: item)
            showStatus("已删除：\(item.title)", positive: true)
        } catch {
            showStatus("删除失败：\(error.localizedDescription)")
        }
    }

    private func performUndo() {
        guard let action = undoAction else { return }
        undoAction = nil
        Haptics.levelChange()
        switch action {
        case .completed(let item):
            do {
                try service.setTaskCompleted(id: item.id, completed: false)
                withAnimation(.easeOut(duration: 0.2)) {
                    if !items.contains(where: { $0.id == item.id }) {
                        items.append(item)
                        items.sort(by: ReminderItem.overviewOrder)
                    }
                }
                showStatus("已恢复待办：\(item.title)", positive: true)
            } catch {
                showStatus("撤销失败：\(error.localizedDescription)")
            }
        case .deleted(let item):
            do {
                let newId = try service.createTask(
                    title: item.title,
                    due: item.dueDate,
                    priority: item.priority,
                    list: item.listName.isEmpty ? nil : item.listName
                )
                let restored = ReminderItem(
                    id: newId,
                    title: item.title,
                    dueDate: item.dueDate,
                    priority: item.priority,
                    listName: item.listName
                )
                withAnimation(.easeOut(duration: 0.2)) {
                    items.append(restored)
                    items.sort(by: ReminderItem.overviewOrder)
                }
                showStatus("已恢复已删除待办：\(item.title)", positive: true)
            } catch {
                showStatus("恢复失败：\(error.localizedDescription)")
            }
        }
    }

    private var snoozeTimeDescription: String {
        String(format: "%02d:%02d", snoozeHour, snoozeMinute)
    }

    private var tomorrowDate: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: snoozeHour, minute: snoozeMinute, second: 0, of: tomorrow) ?? tomorrow
    }

    private var nextWeekDate: Date {
        let cal = Calendar.current
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let daysUntilMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let nextMonday = cal.date(byAdding: .day, value: daysUntilMonday, to: now) ?? now
        return cal.date(bySettingHour: snoozeHour, minute: snoozeMinute, second: 0, of: nextMonday) ?? nextMonday
    }

    // MARK: - Status Bar

    private func statusBar(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIsPositive ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: Design.caption))
                .foregroundStyle(statusIsPositive ? .green : .orange)
            Text(text).font(.system(size: Design.caption))
            Spacer()
            if undoAction != nil {
                Button("撤销 (⌘Z)") {
                    performUndo()
                }
                .font(.system(size: Design.caption, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else if statusIsPositive {
                Button("打开提醒事项") { openRemindersApp() }
                    .font(.system(size: Design.caption))
            }
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func showStatus(_ text: String, positive: Bool = false) {
        statusText = text
        statusIsPositive = positive
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if statusText == text {
                statusText = nil
                undoAction = nil
            }
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
        completedTodayItems = await service.fetchCompletedToday()
    }

    @State private var fallbackReason: String?

    private func matchedListName(_ candidate: String?) -> String {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
            return ""
        }
        if lists.contains(candidate) { return candidate }
        if let exactCase = lists.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return exactCase
        }
        let cleanedCandidate = candidate.replacingOccurrences(of: "列表", with: "")
                                        .replacingOccurrences(of: "清单", with: "")
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedCandidate.isEmpty {
            if let matchCleaned = lists.first(where: { $0 == cleanedCandidate || $0.caseInsensitiveCompare(cleanedCandidate) == .orderedSame }) {
                return matchCleaned
            }
        }
        if let fuzzy = lists.first(where: {
            let item = $0.replacingOccurrences(of: "列表", with: "").replacingOccurrences(of: "清单", with: "")
            return candidate.contains(item) || item.contains(cleanedCandidate) || candidate.contains($0) || $0.contains(candidate)
        }) {
            return fuzzy
        }
        return ""
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

        if lists.isEmpty {
            lists = service.listNames()
        }

        let config = store.config
        isParsing = true
        fallbackReason = nil
        Task {
            defer { isParsing = false }
            let client = TodoLLMClient()
            let context = TodoPromptContext(
                input: text, now: Date(),
                lists: lists, lastList: UserDefaults.standard.string(forKey: "CollectionBox.todo.lastList")
            )
            var results: [ParsedTask] = []
            var caughtError: Error?
            do {
                results = try await client.parseAll(context: context, config: config)
            } catch {
                caughtError = error
                results = []
            }

            if results.count > 1 {
                // 多条待办批量识别
                batchCards = results.map { res in
                    let matchedList = matchedListName(res.list)
                    return EditableTask(
                        title: res.title,
                        due: res.due ?? Date(),
                        hasDue: res.due != nil,
                        priority: res.priority,
                        list: matchedList
                    )
                }
                isBatchPresent = true
                isCardPresent = false
            } else if let result = results.first, !result.title.isEmpty {
                // 单条待办识别
                let matchedList = matchedListName(result.list)
                card = EditableTask(
                    title: result.title,
                    due: result.due ?? Date(),
                    hasDue: result.due != nil,
                    priority: result.priority,
                    list: matchedList
                )
                isFallbackCard = result.fallback
                if result.fallback {
                    fallbackReason = "未能识别明确时间，可手动选择"
                }
                isCardPresent = true
                isBatchPresent = false
            } else {
                // 降级：检查多行输入
                let lines = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                if lines.count > 1 {
                    batchCards = lines.map { line in
                        EditableTask(title: line, due: Date(), hasDue: false, priority: 0, list: "")
                    }
                    isBatchPresent = true
                    isCardPresent = false
                    showStatus("未能通过 AI 识别，已按多行拆分待办")
                } else {
                    card = EditableTask(title: text, due: Date(), hasDue: false, priority: 0, list: "")
                    isFallbackCard = true
                    if let error = caughtError {
                        let nsError = error as NSError
                        if nsError.code == NSURLErrorTimedOut || error.localizedDescription.contains("timed out") || error.localizedDescription.contains("超时") {
                            fallbackReason = "AI 请求超时，已按原文填入"
                        } else {
                            fallbackReason = "\(error.localizedDescription)，已按原文填入"
                        }
                    } else {
                        fallbackReason = "未能识别时间，已按原文填入"
                    }
                    isCardPresent = true
                    isBatchPresent = false
                }
            }
        }
    }

    private func saveBatchCards() {
        guard !batchCards.isEmpty else { return }
        var savedCount = 0
        for item in batchCards {
            let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                try service.createTask(
                    title: trimmed,
                    due: item.hasDue ? item.due : nil,
                    priority: item.priority,
                    list: item.list.isEmpty ? nil : item.list
                )
                savedCount += 1
            } catch {
                showStatus("保存第 \(savedCount + 1) 项失败：\(error.localizedDescription)")
                return
            }
        }
        discardBatchCards()
        input = ""
        Haptics.success()
        showStatus("已批量添加 \(savedCount) 条待办", positive: true)
        Task { await reloadOverview() }
    }

    private func discardBatchCards() {
        isBatchPresent = false
        batchCards.removeAll()
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
        Haptics.success()
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

    private func priorityBgColor(for item: ReminderItem) -> Color {
        if item.isHighPriority {
            return Color.red.opacity(0.14)
        } else if item.isMediumPriority {
            return Color.orange.opacity(0.14)
        } else {
            return Color.secondary.opacity(0.12)
        }
    }

    private func priorityTextColor(for item: ReminderItem) -> Color {
        if item.isHighPriority {
            return Color.red
        } else if item.isMediumPriority {
            return Color.orange
        } else {
            return Color.secondary
        }
    }

    private func listColor(for item: ReminderItem) -> Color {
        if let hex = item.listColorHex, let c = Color(hexString: hex) {
            return c
        }
        let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .yellow]
        let hash = abs(item.listName.hashValue)
        return palette[hash % palette.count]
    }
}

private struct TodoHoverSnoozeButton: View {
    let timeText: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("推迟到明天 \(timeText) (⌘T)")
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct TodoHoverDeleteButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("删除待办 (⌘⌫)")
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private extension Color {
    init?(hexString: String) {
        var str = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let val = UInt64(str, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
