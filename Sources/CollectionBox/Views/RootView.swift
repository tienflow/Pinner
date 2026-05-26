import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable {
    case list
    case grid
}

enum SortOrder: String, CaseIterable {
    case nameAsc = "name_asc"
    case nameDesc = "name_desc"
    case dateAdded = "date_added"
    case type = "type"

    var label: String {
        switch self {
        case .nameAsc: return "名称 A-Z"
        case .nameDesc: return "名称 Z-A"
        case .dateAdded: return "添加时间"
        case .type: return "文件类型"
        }
    }
}

struct RootView: View {
    @State var store: CollectionStore
    @State private var selectedTabID: UUID?
    @State private var isShowingNewTabAlert = false
    @State private var newTabName = ""
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = {
        let raw = UserDefaults.standard.string(forKey: "CollectionBox.sortOrder") ?? "date_added"
        return SortOrder(rawValue: raw) ?? .dateAdded
    }()
    @State private var viewMode: ViewMode = {
        let raw = UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list"
        return ViewMode(rawValue: raw) ?? .list
    }()
    @State private var clickedEntryID: UUID?

    private var filteredEntries: [BookmarkEntry] {
        guard let tabID = selectedTabID,
              let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) else { return [] }
        let entries = store.tabs[tabIndex].entries
        let filtered = searchText.isEmpty ? entries : entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case .nameAsc:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .nameDesc:
            return filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .dateAdded:
            return filtered
        case .type:
            return filtered.sorted { fileExtension($0.displayName).localizedCaseInsensitiveCompare(fileExtension($1.displayName)) == .orderedAscending }
        }
    }

    private func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            searchBar
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

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button(action: {
                        sortOrder = order
                        UserDefaults.standard.set(order.rawValue, forKey: "CollectionBox.sortOrder")
                    }) {
                        HStack {
                            Text(order.label)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("排序方式")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                        listView(tabIndex: tabIndex)
                    } else {
                        gridView(tabIndex: tabIndex)
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

    private func listView(tabIndex: Int) -> some View {
        List {
            ForEach(filteredEntries) { entry in
                EntryRow(entry: entry, isClicked: clickedEntryID == entry.id) {
                    openEntry(entry)
                    flashEntry(entry.id)
                }
                .contextMenu {
                    entryContextMenu(entry: entry, tabIndex: tabIndex)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Grid View

    private func gridView(tabIndex: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)
            ], spacing: 12) {
                ForEach(filteredEntries) { entry in
                    GridEntryItem(entry: entry, isClicked: clickedEntryID == entry.id) {
                        openEntry(entry)
                        flashEntry(entry.id)
                    }
                    .contextMenu {
                        entryContextMenu(entry: entry, tabIndex: tabIndex)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Entry Context Menu

    @ViewBuilder
    private func entryContextMenu(entry: BookmarkEntry, tabIndex: Int) -> some View {
        let isFirst = filteredEntries.first?.id == entry.id
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

    // MARK: - Click Feedback

    private func flashEntry(_ id: UUID) {
        clickedEntryID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if clickedEntryID == id {
                clickedEntryID = nil
            }
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
    var isClicked: Bool = false
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(fileName: entry.displayName)
                .frame(width: 20, height: 20)
            Text(entry.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isClicked ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isClicked: Bool = false
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            FileIconView(fileName: entry.displayName)
                .frame(width: 48, height: 48)
                .frame(width: 64, height: 64)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isClicked ? Color.accentColor : Color.clear, lineWidth: 2)
                )

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
}

// MARK: - File Icon (uses macOS system icons)

struct FileIconView: View {
    let fileName: String

    var body: some View {
        FileIconNSImageRepresentable(fileName: fileName)
    }
}

#if canImport(AppKit)
struct FileIconNSImageRepresentable: NSViewRepresentable {
    let fileName: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = iconForFile(fileName)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = iconForFile(fileName)
    }

    private func iconForFile(_ name: String) -> NSImage {
        let ext = (name as NSString).pathExtension
        if ext.isEmpty {
            return NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
        }
        return NSWorkspace.shared.icon(forFileType: ext)
    }
}
#else
struct FileIconNSImageRepresentable: View {
    let fileName: String
    var body: some View {
        Image(systemName: fileName.contains(".") ? "doc" : "folder")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
    }
}
#endif
