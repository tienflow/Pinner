import SwiftUI
import AppKit

/// Quick-capture panel for fleeting thoughts → Apple Notes.
///
/// Pattern:
/// 1. Quick-target capsules on top (dynamic LRU recents)
/// 2. Natural language input area
/// 3. Two-stage confirmation card: Enter to analyze/preview, Enter to save & dismiss
/// 4. Cmd+Enter for instant one-shot routing & delivery
public struct FleetingCaptureView: View {
    @State private var input = ""
    @State private var isParsing = false
    @State private var isPolishing = false
    @State private var isSaving = false
    @State private var isCardPresent = false

    // Editable fields in confirmation card
    @State private var selectedFolder: String = ""
    @State private var selectedNote: String = ""
    @State private var isCreatingNewNote = false
    @State private var insertionMode: NoteInsertionMode = .append
    @State private var formattedContent = ""

    // Discovery state
    @State private var folderTree: [AppleNotesService.FolderItem] = []

    // Feedback status
    @State private var statusMessage: String?
    @State private var statusIsError = false

    @ObservedObject private var settingsStore = FleetingSettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    public var onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            VStack(spacing: 12) {
                if !settingsStore.recentTargets.isEmpty {
                    quickPillsBar
                }
                inputSection

                if isParsing {
                    parsingIndicator
                } else if isCardPresent {
                    confirmationCard
                }

                if let msg = statusMessage {
                    statusBar(text: msg, isError: statusIsError)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .onAppear {
            // 每次打开保持全新干净状态，绝不默认锁死在历史目标，由意图识别纯净推导
            selectedFolder = ""
            selectedNote = ""
            isCreatingNewNote = false

            // 静默预热备忘录目录树内存缓存，保证敲击回车时 0ms 瞬间直出
            Task.detached(priority: .utility) {
                _ = try? await AppleNotesService.shared.getFolderTree()
            }
        }
        .onChange(of: isCardPresent) { _, expanded in
            FleetingCaptureWindowController.shared.updateHeight(isExpanded: expanded, isParsing: isParsing, hasStatus: statusMessage != nil)
        }
        .onChange(of: isParsing) { _, parsing in
            FleetingCaptureWindowController.shared.updateHeight(isExpanded: isCardPresent, isParsing: parsing, hasStatus: statusMessage != nil)
        }
        .onChange(of: statusMessage) { _, msg in
            FleetingCaptureWindowController.shared.updateHeight(isExpanded: isCardPresent, isParsing: isParsing, hasStatus: msg != nil)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text.badge.plus")
                .foregroundColor(.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("闪念投递")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
    }

    // MARK: - Quick Pills Bar

    private var quickPillsBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settingsStore.recentTargets) { target in
                        let isSelected = selectedNote == target.note && selectedFolder == target.folder
                        pillButton(target: target, isSelected: isSelected) {
                            if isSelected {
                                selectedFolder = ""
                                selectedNote = ""
                            } else {
                                selectTargetNote(target)
                            }
                        } onDelete: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                settingsStore.removeTarget(id: target.id)
                                if selectedNote == target.note && selectedFolder == target.folder {
                                    selectedFolder = ""
                                    selectedNote = ""
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            if !selectedNote.isEmpty && !isCardPresent {
                Button(action: {
                    selectedFolder = ""
                    selectedNote = ""
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                        Text("取消选中")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("取消当前锁定的目标笔记")
            }
        }
    }

    private func pillButton(target: RecentTarget, isSelected: Bool, action: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: action) {
                Text(target.note)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .primary)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isSelected ? .accentColor.opacity(0.8) : .secondary.opacity(0.55))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("从历史选择中删除《\(target.note)》")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 0.8)
        )
        .contextMenu {
            Button("从历史选择中删除", role: .destructive) {
                onDelete()
            }
            Divider()
            Button("清空全部历史选择", role: .destructive) {
                settingsStore.clearAllTargets()
                selectedFolder = ""
                selectedNote = ""
            }
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("记录当下的灵感、日常或随笔…（回车展开推导，⌘↵ 极速投递）")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }

                TextEditor(text: $input)
                    .font(.system(size: 12))
                    .frame(height: 76)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .background(
                RoundedRectangle(cornerRadius: Design.radiusM, style: .continuous)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.radiusM, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.8)
            )

            HStack(spacing: 8) {
                Text("↵ 展开确认")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("⌘↵ 极速投递")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()

                Button(action: { Task { await polishInput() } }) {
                    HStack(spacing: 3) {
                        if isPolishing {
                            ProgressView().scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10))
                        }
                        Text("AI 润色")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    .cornerRadius(6)
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPolishing || isParsing)
                .help("AI 润色：修正错别字与语病，提升语句流畅度，保真原意")

                Button(action: { Task { await analyzeInput() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text(isCardPresent ? "重新推导" : "智能推导")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(6)
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing || isPolishing)
            }
        }
        .onKeyPress(phases: .down) { press in
            if press.key == .return {
                if press.modifiers.contains(.command) {
                    Task { await directCommit() }
                    return .handled
                } else if !isCardPresent {
                    Task { await analyzeInput() }
                    return .handled
                } else {
                    Task { await commitWrite() }
                    return .handled
                }
            } else if press.key == .escape {
                onClose?()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Parsing Indicator

    private var parsingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("正在智能匹配目标备忘录…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Confirmation Card

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Target Folder & Note (Dropdown Menus)
            HStack(spacing: 8) {
                // Folder Dropdown
                VStack(alignment: .leading, spacing: 3) {
                    Text("分类文件夹")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    let folders = folderTree.map(\.name).filter { $0 != "Recently Deleted" && $0 != "最近删除" }
                    Menu {
                        if !selectedFolder.isEmpty {
                            Button("不限分类 / 清除分类") {
                                selectedFolder = ""
                            }
                            Divider()
                        }
                        ForEach(folders, id: \.self) { folder in
                            Button(action: {
                                selectedFolder = folder
                                isCreatingNewNote = false
                                let notes = notesForCurrentFolder()
                                if !notes.contains(selectedNote) {
                                    selectedNote = notes.first ?? ""
                                }
                            }) {
                                HStack {
                                    Text(folder)
                                    if selectedFolder == folder {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                            Text(selectedFolder.isEmpty ? "选择分类" : selectedFolder)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                }
                .frame(maxWidth: .infinity)

                // Note Dropdown
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("目标笔记")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        if isCreatingNewNote {
                            Button("从已有选择") {
                                isCreatingNewNote = false
                                selectedNote = notesForCurrentFolder().first ?? ""
                                insertionMode = .append
                            }
                            .font(.system(size: 9))
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    }

                    if isCreatingNewNote {
                        TextField("新笔记标题", text: $selectedNote)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
                            .cornerRadius(6)
                    } else {
                        let notes = notesForCurrentFolder()
                        Menu {
                            if !selectedNote.isEmpty {
                                Button("清除笔记选择") {
                                    selectedNote = ""
                                }
                                Divider()
                            }
                            ForEach(notes, id: \.self) { note in
                                Button(action: {
                                    selectedNote = note
                                    isCreatingNewNote = false
                                }) {
                                    HStack {
                                        Text(note)
                                        if selectedNote == note {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button(action: {
                                isCreatingNewNote = true
                                selectedNote = ""
                                insertionMode = .create
                            }) {
                                Label("新建笔记...", systemImage: "plus")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                    .foregroundColor(.accentColor)
                                Text(selectedNote.isEmpty ? "选择笔记" : selectedNote)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.05))
                            .cornerRadius(6)
                        }
                        .menuStyle(.borderlessButton)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Row 2: Mode Toggle Capsule
            VStack(alignment: .leading, spacing: 4) {
                Text("插入模式")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(NoteInsertionMode.allCases) { mode in
                        let isSelected = insertionMode == mode
                        Button(action: { insertionMode = mode }) {
                            Text(mode.label)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.secondary.opacity(colorScheme == .dark ? 0.1 : 0.04))
                .cornerRadius(6)
            }

            // Row 3: Formatted Content Preview & Edit
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("投递内容（可就地微调，真实保真）")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                TextEditor(text: $formattedContent)
                    .font(.system(size: 11))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.045))
                    .cornerRadius(5)
            }

            // Row 4: Action Buttons
            HStack {
                Button("取消") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCardPresent = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

                Spacer()

                Button(action: { Task { await commitWrite() } }) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text("存入备忘录 (↵)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM, style: .continuous)
                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.08 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.8)
        )
    }

    // MARK: - Status Bar

    private func statusBar(text: String, isError: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((isError ? Color.red : Color.green).opacity(0.12))
        )
    }

    // MARK: - Actions & Logistics

    private func notesForCurrentFolder() -> [String] {
        if let folderItem = folderTree.first(where: { $0.name == selectedFolder }) {
            return folderItem.notes
        }
        return []
    }

    private func selectTargetNote(_ target: RecentTarget) {
        selectedFolder = target.folder
        selectedNote = target.note
        if target.note.contains("日志") || target.note.contains("打卡") {
            insertionMode = .prepend
        } else {
            insertionMode = .append
        }
    }

    private func polishInput() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isPolishing = true
        statusMessage = nil

        let config = TodoSettingsStore.shared.config
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            statusIsError = true
            statusMessage = "请先在设置中配置大模型 API Key 与地址"
            isPolishing = false
            return
        }

        let client = FleetingThoughtLLMClient()
        do {
            let polished = try await client.polish(text: trimmed, config: config)
            input = polished
            if isCardPresent {
                formattedContent = polished
            }
            statusIsError = false
            statusMessage = "已完成文字润色"
        } catch {
            statusIsError = true
            statusMessage = "润色失败: \(error.localizedDescription)"
        }
        isPolishing = false
    }

    private func analyzeInput() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isParsing = true
        statusMessage = nil

        // 按需拉取备忘录完整分类与已有笔记树，开窗绝不提前偷跑触碰权限
        if folderTree.isEmpty {
            if let tree = try? await AppleNotesService.shared.getFolderTree(), !tree.isEmpty {
                self.folderTree = tree
            }
        }

        let context = FleetingPrompt.Context(
            input: trimmed,
            folderTree: folderTree,
            lastFolder: selectedFolder.isEmpty ? nil : selectedFolder,
            lastNote: selectedNote.isEmpty ? nil : selectedNote,
            now: Date()
        )

        let client = FleetingThoughtLLMClient()
        let config = TodoSettingsStore.shared.config

        do {
            let parsed = try await client.parse(context: context, config: config)
            selectedFolder = parsed.folder
            selectedNote = parsed.targetNoteTitle
            insertionMode = parsed.mode
            formattedContent = parsed.formattedContent
            withAnimation(.easeInOut(duration: 0.2)) {
                isCardPresent = true
            }
        } catch {
            let fallback = FleetingThoughtLLMClient.localFallback(context: context)
            selectedFolder = fallback.folder
            selectedNote = fallback.targetNoteTitle
            insertionMode = fallback.mode
            formattedContent = fallback.formattedContent
            withAnimation(.easeInOut(duration: 0.2)) {
                isCardPresent = true
            }
        }

        isParsing = false
    }

    private func directCommit() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !isCardPresent {
            await analyzeInput()
        }
        await commitWrite()
    }

    private func commitWrite() async {
        let trimmedContent = formattedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        let targetFolder = selectedFolder.isEmpty ? (folderTree.first?.name ?? "Notes") : selectedFolder
        let targetNote = selectedNote.isEmpty ? "日常随笔" : selectedNote

        isSaving = true
        do {
            try await AppleNotesService.shared.write(
                title: targetNote,
                folder: targetFolder,
                content: trimmedContent,
                mode: insertionMode
            )
            settingsStore.recordTarget(folder: targetFolder, note: targetNote)

            statusIsError = false
            statusMessage = "已成功投递至《\(targetNote)》"

            // Smooth fade out and close
            try? await Task.sleep(nanoseconds: 600_000_000)
            onClose?()
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
        isSaving = false
    }
}
