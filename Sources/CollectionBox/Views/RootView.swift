import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable {
    case list
    case grid
}

enum SortOrder: String, CaseIterable {
    case name = "name"
    case dateAdded = "date_added"
    case lastOpened = "last_opened"
    case type = "type"

    var label: String {
        switch self {
        case .name: return "名称"
        case .dateAdded: return "添加时间"
        case .lastOpened: return "上次打开时间"
        case .type: return "文件类型"
        }
    }
}

struct EntrySection: Identifiable {
    let id: String
    let title: String
    let entries: [BookmarkEntry]
}

struct RootView: View {
    @State var store: CollectionStore
    @State private var selectedTabID: UUID?
    @State private var isShowingNewTabAlert = false
    @State private var newTabName = ""
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @State private var flashID: UUID?
    @State private var nameAscending = true
    @State private var sortOrder: SortOrder = {
        let raw = UserDefaults.standard.string(forKey: "CollectionBox.sortOrder") ?? "date_added"
        return SortOrder(rawValue: raw) ?? .dateAdded
    }()
    @State private var viewMode: ViewMode = {
        let raw = UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list"
        return ViewMode(rawValue: raw) ?? .list
    }()

    private var sortedEntries: [BookmarkEntry] {
        guard let tabID = selectedTabID,
              let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) else { return [] }
        let entries = store.tabs[tabIndex].entries
        let filtered = searchText.isEmpty ? entries : entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
        switch sortOrder {
        case .name:
            return nameAscending
                ? filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                : filtered.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .dateAdded:
            return filtered.sorted { $0.dateAdded > $1.dateAdded }
        case .lastOpened:
            return filtered.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        case .type:
            return filtered.sorted {
                let e1 = ($0.displayName as NSString).pathExtension.lowercased()
                let e2 = ($1.displayName as NSString).pathExtension.lowercased()
                if e1 == e2 { return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                return e1 < e2
            }
        }
    }

    private var sections: [EntrySection] {
        switch sortOrder {
        case .type: return groupByType(sortedEntries)
        case .dateAdded: return groupByDate(sortedEntries.map { ($0, $0.dateAdded) })
        case .lastOpened: return groupByDate(sortedEntries.compactMap { e in e.lastOpened.map { (e, $0) } })
        default: return [EntrySection(id: "all", title: "", entries: sortedEntries)]
        }
    }

    private func groupByType(_ entries: [BookmarkEntry]) -> [EntrySection] {
        var groups = [String: [BookmarkEntry]]()
        for e in entries {
            let ext = (e.displayName as NSString).pathExtension.lowercased()
            let key = ext.isEmpty ? "其他" : ext.uppercased()
            groups[key, default: []].append(e)
        }
        return groups.keys.sorted().map { EntrySection(id: "type_\($0)", title: $0, entries: groups[$0]!) }
    }

    private func groupByDate(_ pairs: [(BookmarkEntry, Date)]) -> [EntrySection] {
        let cal = Calendar.current
        let now = Date()
        var buckets = [String: (order: Int, entries: [BookmarkEntry])]()

        for (e, date) in pairs {

            let key: String
            let order: Int

            if cal.isDateInToday(date) || cal.isDateInYesterday(date) {
                key = "今天"
                order = 0
            } else if let daysAgo = cal.dateComponents([.day], from: date, to: now).day, daysAgo <= 7 {
                key = "最近 7 天"
                order = 1
            } else if cal.isDate(date, equalTo: now, toGranularity: .month) {
                key = "本月"
                order = 2
            } else if cal.isDate(date, equalTo: now, toGranularity: .year) {
                let month = cal.component(.month, from: date)
                key = "\(month) 月"
                order = 2 + month
            } else {
                let year = cal.component(.year, from: date)
                key = "\(year) 年"
                order = 100 + year
            }

            buckets[key, default: (order, [])].entries.append(e)
        }

        return buckets
            .sorted { $0.value.order < $1.value.order }
            .map { EntrySection(id: "date_\($0.key)", title: $0.key, entries: $0.value.entries) }
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
            if selectedTabID == nil { selectedTabID = store.tabs.first?.id }
            NotificationCenter.default.addObserver(
                forName: .collectionBoxKeyDown, object: nil, queue: .main
            ) { handleKeyDown($0) }
        }
        .alert("新建收藏夹", isPresented: $isShowingNewTabAlert) {
            TextField("收藏夹名称", text: $newTabName)
            Button("创建") {
                let name = newTabName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.createTab(named: name); selectedTabID = store.tabs.last?.id }
                newTabName = ""
            }
            .disabled(newTabName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) { newTabName = "" }
        } message: { Text("输入收藏夹名称") }
        .alert("重命名收藏夹", isPresented: .init(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确认") {
                if let id = renamingTabID, let i = store.tabs.firstIndex(where: { $0.id == id }) {
                    let n = renameText.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { store.renameTab(at: i, to: n) }
                }
                renamingTabID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) { renamingTabID = nil }
        } message: { Text("输入新名称") }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                Button(action: { selectedTabID = tab.id }) {
                    Text(tab.name)
                        .font(.system(size: 12, weight: tab.id == selectedTabID ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(tab.id == selectedTabID ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("重命名") { renameText = tab.name; renamingTabID = tab.id }
                    Divider()
                    Button("删除", role: .destructive) {
                        if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) {
                            store.deleteTab(at: i)
                            if selectedTabID == tab.id { selectedTabID = store.tabs.first?.id }
                        }
                    }
                }
            }
            Spacer()
            Button(action: { viewMode = viewMode == .list ? .grid : .list; UserDefaults.standard.set(viewMode.rawValue, forKey: "CollectionBox.viewMode") }) {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            Button(action: { newTabName = ""; isShowingNewTabAlert = true }) {
                Image(systemName: "plus").font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索", text: $searchText).textFieldStyle(.plain).font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if sortOrder == .name {
                Button(action: { nameAscending.toggle() }) {
                    Image(systemName: nameAscending ? "arrow.up" : "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(nameAscending ? "名称 A→Z" : "名称 Z→A")
            }
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                        UserDefaults.standard.set(order.rawValue, forKey: "CollectionBox.sortOrder")
                    } label: {
                        HStack { Text(order.label); if sortOrder == order { Image(systemName: "checkmark") } }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Entry Content

    @ViewBuilder
    private var entryContent: some View {
        if let tabID = selectedTabID, let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) {
            if store.tabs[tabIndex].entries.isEmpty {
                emptyState.onDrop(of: [.fileURL], isTargeted: nil) { handleDrop(providers: $0, tabIndex: tabIndex) }
            } else {
                Group {
                    if viewMode == .list { sectionedListView(tabIndex: tabIndex) }
                    else { sectionedGridView(tabIndex: tabIndex) }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop(providers: $0, tabIndex: tabIndex) }
            }
        } else {
            VStack { Spacer(); Text("点击 + 创建一个收藏夹").foregroundStyle(.secondary); Spacer() }
        }
    }

    // MARK: - Sectioned List

    private func sectionedListView(tabIndex: Int) -> some View {
        List {
            ForEach(sections) { section in
                if !section.title.isEmpty {
                    Section(header: Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                        rows(section: section, tabIndex: tabIndex)
                    }
                } else {
                    rows(section: section, tabIndex: tabIndex)
                }
            }
        }
        .listStyle(.plain)
    }

    private func rows(section: EntrySection, tabIndex: Int) -> some View {
        ForEach(section.entries) { entry in
            EntryRow(entry: entry, isSelected: selectedEntryID == entry.id, isFlashing: flashID == entry.id)
                .contentShape(Rectangle())
                .onTapGesture { selectedEntryID = entry.id }
                .onTapGesture(count: 2) { openEntry(entry, tabIndex: tabIndex) }
                .contextMenu { entryContextMenu(entry: entry, tabIndex: tabIndex) }
        }
    }

    // MARK: - Sectioned Grid

    private func sectionedGridView(tabIndex: Int) -> some View {
        ScrollView {
            ForEach(sections) { section in
                if !section.title.isEmpty {
                    HStack { Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer() }
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)], spacing: 12) {
                    ForEach(section.entries) { entry in
                        GridEntryItem(entry: entry, isSelected: selectedEntryID == entry.id, isFlashing: flashID == entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedEntryID = entry.id }
                            .onTapGesture(count: 2) { openEntry(entry, tabIndex: tabIndex) }
                            .contextMenu { entryContextMenu(entry: entry, tabIndex: tabIndex) }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func entryContextMenu(entry: BookmarkEntry, tabIndex: Int) -> some View {
        if sortedEntries.first?.id != entry.id {
            Button { store.pinEntry(entry.id, in: tabIndex) } label: { Label("置顶", systemImage: "pin") }
        }
        Button("在 Finder 中显示") { showInFinder(entry.bookmarkData) }
        Divider()
        Button("移除", role: .destructive) {
            store.removeEntry(entry.id, from: tabIndex)
            if selectedEntryID == entry.id { selectedEntryID = nil }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray.and.arrow.down").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("拖拽文件到此处，收藏常用文件（夹）").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ notification: Notification) {
        guard let key = notification.userInfo?["key"] as? String else { return }
        let entries = sortedEntries
        guard !entries.isEmpty else { return }

        switch key {
        case "up":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i > 0 {
                selectedEntryID = entries[i - 1].id
            } else { selectedEntryID = entries.last?.id }
        case "down":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i < entries.count - 1 {
                selectedEntryID = entries[i + 1].id
            } else { selectedEntryID = entries.first?.id }
        case "space", "return":
            if let id = selectedEntryID, let entry = entries.first(where: { $0.id == id }),
               let tabID = selectedTabID, let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) {
                openEntry(entry, tabIndex: tabIndex)
            }
        default: break
        }
    }

    // MARK: - Flash

    private func flashEntry(_ id: UUID) {
        flashID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if flashID == id { flashID = nil } }
    }

    // MARK: - Drop

    private func handleDrop(providers: [NSItemProvider], tabIndex: Int) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    do {
                        let d = try BookmarkService.makeBookmark(for: url)
                        store.addEntry(BookmarkEntry(id: UUID(), displayName: url.lastPathComponent, bookmarkData: d), to: tabIndex)
                    } catch { print("Bookmark error: \(error)") }
                }
            }
        }
        return true
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack { Text("\(sortedEntries.count) 个项目").font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
            .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Actions

    private func showInFinder(_ data: Data) {
        BookmarkService.withResolvedBookmark(data) { url in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                NSWorkspace.shared.open(url)
            } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func openEntry(_ entry: BookmarkEntry, tabIndex: Int) {
        BookmarkService.withResolvedBookmark(entry.bookmarkData) { url in NSWorkspace.shared.open(url) }
        store.recordOpen(entry.id, in: tabIndex)
        flashEntry(entry.id)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let collectionBoxKeyDown = Notification.Name("CollectionBoxKeyDown")
}

// MARK: - Entry Row

struct EntryRow: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(fileName: entry.displayName).frame(width: 20, height: 20)
            Text(entry.displayName).font(.system(size: 13)).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(isFlashing ? Color.accentColor.opacity(0.10) : (isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        .cornerRadius(4)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false

    var body: some View {
        VStack(spacing: 4) {
            FileIconView(fileName: entry.displayName)
                .frame(width: 40, height: 40)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            Text(entry.displayName)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72, height: 28)
        }
        .frame(width: 80, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isFlashing ? Color.accentColor.opacity(0.10) : (isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        )
    }
}

// MARK: - File Icon

struct FileIconView: View {
    let fileName: String
    var body: some View { FileIconNSImageRepresentable(fileName: fileName) }
}

#if canImport(AppKit)
struct FileIconNSImageRepresentable: NSViewRepresentable {
    let fileName: String
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(); v.imageScaling = .scaleProportionallyUpOrDown; v.image = icon(); return v
    }
    func updateNSView(_ nsView: NSImageView, context: Context) { nsView.image = icon() }
    private func icon() -> NSImage {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon))) : NSWorkspace.shared.icon(forFileType: ext)
    }
}
#else
struct FileIconNSImageRepresentable: View {
    let fileName: String
    var body: some View { Image(systemName: fileName.contains(".") ? "doc" : "folder").font(.system(size: 24)) }
}
#endif
