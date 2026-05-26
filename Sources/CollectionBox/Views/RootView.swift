import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable {
    case list
    case grid
}

struct RootView: View {
    @State var store: CollectionStore
    @State private var selectedTabID: UUID?
    @State private var isShowingNewTabAlert = false
    @State private var newTabName = ""
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var viewMode: ViewMode = {
        let raw = UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list"
        return ViewMode(rawValue: raw) ?? .list
    }()

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            entryContent
            Divider()
            bottomBar
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 400)
        .onAppear {
            if selectedTabID == nil {
                selectedTabID = store.tabs.first?.id
            }
        }
        .alert("新建收藏夹", isPresented: $isShowingNewTabAlert) {
            TextField("收藏夹名称", text: $newTabName)
            Button("创建") {
                let name = newTabName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    store.createTab(named: name)
                    selectedTabID = store.tabs.last?.id
                }
                newTabName = ""
            }
            .disabled(newTabName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) { newTabName = "" }
        } message: {
            Text("输入收藏夹名称")
        }
        .alert("重命名收藏夹", isPresented: .init(
            get: { renamingTabID != nil },
            set: { if !$0 { renamingTabID = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("确认") {
                if let tabID = renamingTabID,
                   let index = store.tabs.firstIndex(where: { $0.id == tabID }) {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { store.renameTab(at: index, to: name) }
                }
                renamingTabID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) { renamingTabID = nil }
        } message: {
            Text("输入新名称")
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                tabButton(tab)
                    .contextMenu {
                        Button("重命名") {
                            renameText = tab.name
                            renamingTabID = tab.id
                        }
                        Divider()
                        Button("删除", role: .destructive) {
                            if let index = store.tabs.firstIndex(where: { $0.id == tab.id }) {
                                store.deleteTab(at: index)
                                if selectedTabID == tab.id {
                                    selectedTabID = store.tabs.first?.id
                                }
                            }
                        }
                    }
            }
            Spacer()
            viewModeToggle
            addTabButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabButton(_ tab: CollectionTab) -> some View {
        Button(action: { selectedTabID = tab.id }) {
            Text(tab.name)
                .font(.system(size: 12, weight: tab.id == selectedTabID ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(tab.id == selectedTabID ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private var viewModeToggle: some View {
        Button(action: {
            viewMode = viewMode == .list ? .grid : .list
            UserDefaults.standard.set(viewMode.rawValue, forKey: "CollectionBox.viewMode")
        }) {
            Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .help(viewMode == .list ? "切换到宫格视图" : "切换到列表视图")
    }

    private var addTabButton: some View {
        Button(action: {
            newTabName = ""
            isShowingNewTabAlert = true
        }) {
            Image(systemName: "plus")
                .font(.system(size: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Entry Content

    @ViewBuilder
    private var entryContent: some View {
        if let tabID = selectedTabID,
           let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) {
            if store.tabs[tabIndex].entries.isEmpty {
                emptyState
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers, tabIndex: tabIndex)
                    }
            } else {
                Group {
                    if viewMode == .list {
                        listView(entries: store.tabs[tabIndex].entries, tabIndex: tabIndex)
                    } else {
                        gridView(entries: store.tabs[tabIndex].entries, tabIndex: tabIndex)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, tabIndex: tabIndex)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("点击 + 创建一个收藏夹")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - List View

    private func listView(entries: [BookmarkEntry], tabIndex: Int) -> some View {
        List {
            ForEach(entries) { entry in
                EntryRow(entry: entry) {
                    openEntry(entry)
                }
                .contextMenu {
                    entryContextMenu(entry: entry, tabIndex: tabIndex, isFirst: entries.first?.id == entry.id)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grid View

    private func gridView(entries: [BookmarkEntry], tabIndex: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)
            ], spacing: 12) {
                ForEach(entries) { entry in
                    GridEntryItem(entry: entry) {
                        openEntry(entry)
                    }
                    .contextMenu {
                        entryContextMenu(entry: entry, tabIndex: tabIndex, isFirst: entries.first?.id == entry.id)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Entry Context Menu

    @ViewBuilder
    private func entryContextMenu(entry: BookmarkEntry, tabIndex: Int, isFirst: Bool) -> some View {
        if !isFirst {
            Button {
                store.pinEntry(entry.id, in: tabIndex)
            } label: {
                Label("置顶", systemImage: "pin")
            }
        }
        Button("在 Finder 中显示") {
            showInFinder(entry.bookmarkData)
        }
        Divider()
        Button("移除", role: .destructive) {
            store.removeEntry(entry.id, from: tabIndex)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("拖拽文件到此处，收藏常用内容")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], tabIndex: Int) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    do {
                        let bookmarkData = try BookmarkService.makeBookmark(for: url)
                        let entry = BookmarkEntry(
                            id: UUID(),
                            displayName: url.lastPathComponent,
                            bookmarkData: bookmarkData
                        )
                        store.addEntry(entry, to: tabIndex)
                    } catch {
                        print("Failed to create bookmark: \(error)")
                    }
                }
            }
        }
        return true
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Text("\(currentTabEntryCount) 个项目")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var currentTabEntryCount: Int {
        guard let tabID = selectedTabID,
              let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) else { return 0 }
        return store.tabs[tabIndex].entries.count
    }

    // MARK: - Actions

    private func showInFinder(_ bookmarkData: Data) {
        BookmarkService.withResolvedBookmark(bookmarkData) { url in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func openEntry(_ entry: BookmarkEntry) {
        BookmarkService.withResolvedBookmark(entry.bookmarkData) { url in
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Entry Row (List)

struct EntryRow: View {
    let entry: BookmarkEntry
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(entry.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
    }

    private var icon: String {
        entry.displayName.contains(".") ? "doc" : "folder"
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)

            Text(entry.displayName)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
    }

    private var icon: String {
        entry.displayName.contains(".") ? "doc" : "folder"
    }
}
