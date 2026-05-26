import SwiftUI
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable { case list, grid }
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
    var onPinToggle: (() -> Void)?
    @State private var isPinnedState: Bool = false
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
        SortOrder(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.sortOrder") ?? "date_added") ?? .dateAdded
    }()
    @State private var viewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list") ?? .list
    }()

    private var allFiltered: [BookmarkEntry] {
        guard let tabID = selectedTabID, let ti = store.tabs.firstIndex(where: { $0.id == tabID }) else { return [] }
        let entries = store.tabs[ti].entries
        return searchText.isEmpty ? entries : entries.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var pinnedEntries: [BookmarkEntry] {
        let pinned = allFiltered.filter { $0.isPinned }
        return pinned.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var sortedEntries: [BookmarkEntry] {
        let unpinned = allFiltered.filter { !$0.isPinned }
        switch sortOrder {
        case .name: return nameAscending
            ? unpinned.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            : unpinned.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedDescending }
        case .dateAdded: return unpinned.sorted { $0.dateAdded > $1.dateAdded }
        case .lastOpened: return unpinned.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        case .type: return unpinned.sorted {
            let e1 = ($0.displayName as NSString).pathExtension.lowercased()
            let e2 = ($1.displayName as NSString).pathExtension.lowercased()
            return e1 == e2 ? $0.displayName < $1.displayName : e1 < e2
        }
        }
    }

    private var sections: [EntrySection] {
        var result: [EntrySection] = []
        if !pinnedEntries.isEmpty {
            result.append(EntrySection(id: "pinned", title: "已置顶", entries: pinnedEntries))
        }
        let unsorted: [EntrySection]
        switch sortOrder {
        case .type: unsorted = groupByType(sortedEntries)
        case .dateAdded: unsorted = groupByDate(sortedEntries.compactMap { e in (e, e.dateAdded) })
        case .lastOpened: unsorted = groupByDate(sortedEntries.compactMap { e in e.lastOpened.map { (e, $0) } })
        default: unsorted = [EntrySection(id: "all", title: "", entries: sortedEntries)]
        }
        result.append(contentsOf: unsorted)
        return result
    }

    private func groupByType(_ entries: [BookmarkEntry]) -> [EntrySection] {
        var g = [String: [BookmarkEntry]]()
        for e in entries {
            let ext = (e.displayName as NSString).pathExtension.lowercased()
            g[ext.isEmpty ? "其他" : ext.uppercased(), default: []].append(e)
        }
        return g.keys.sorted().map { EntrySection(id: "t_\($0)", title: $0, entries: g[$0]!) }
    }

    private func groupByDate(_ pairs: [(BookmarkEntry, Date)]) -> [EntrySection] {
        let cal = Calendar.current
        let now = Date()
        var b = [String: (order: Int, entries: [BookmarkEntry])]()
        for (e, d) in pairs {
            let key: String; var order: Int
            if cal.isDateInToday(d) { key = "今天"; order = 0 }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days <= 7 { key = "最近 7 天"; order = 1 }
            else if cal.isDate(d, equalTo: now, toGranularity: .month) { key = "本月"; order = 2 }
            else if cal.isDate(d, equalTo: now, toGranularity: .year) { key = "\(cal.component(.month, from: d)) 月"; order = 2 + cal.component(.month, from: d) }
            else { let y = cal.component(.year, from: d); key = "\(y) 年"; order = 100 + y }
            b[key, default: (order, [])].entries.append(e)
            b[key]!.order = order
        }
        return b.sorted { $0.value.order < $1.value.order }.map { EntrySection(id: "d_\($0.key)", title: $0.key, entries: $0.value.entries) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar; Divider(); searchBar; Divider(); entryContent; Divider(); bottomBar
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 400)
        .onAppear {
            if selectedTabID == nil { selectedTabID = store.tabs.first?.id }
            isPinnedState = UserDefaults.standard.bool(forKey: "CollectionBox.isPinned")
            NotificationCenter.default.addObserver(forName: .collectionBoxKeyDown, object: nil, queue: .main) { handleKeyDown($0) }
        }
        .alert("新建收藏夹", isPresented: $isShowingNewTabAlert) {
            TextField("收藏夹名称", text: $newTabName)
            Button("创建") { let n = newTabName.trimmingCharacters(in: .whitespaces); if !n.isEmpty { store.createTab(named: n); selectedTabID = store.tabs.last?.id }; newTabName = "" }
                .disabled(newTabName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) { newTabName = "" }
        } message: { Text("输入收藏夹名称") }
        .alert("重命名", isPresented: .init(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确认") { if let id = renamingTabID, let i = store.tabs.firstIndex(where: { $0.id == id }) { let n = renameText.trimmingCharacters(in: .whitespaces); if !n.isEmpty { store.renameTab(at: i, to: n) } }; renamingTabID = nil }
            Button("取消", role: .cancel) { renamingTabID = nil }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
                Button(action: { selectedTabID = tab.id }) {
                    Text(tab.name).font(.system(size: 12, weight: tab.id == selectedTabID ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(tab.id == selectedTabID ? Color.accentColor.opacity(0.15) : Color.clear).cornerRadius(4)
                }.buttonStyle(.plain).contextMenu {
                    Button("重命名") { renameText = tab.name; renamingTabID = tab.id }; Divider()
                    Button("删除", role: .destructive) { if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) { store.deleteTab(at: i); if selectedTabID == tab.id { selectedTabID = store.tabs.first?.id } } }
                }
            }
            Spacer()
            Button(action: { onPinToggle?(); isPinnedState.toggle() }) {
                Image(systemName: isPinnedState ? "pin.fill" : "pin.slash").font(.system(size: 12)).foregroundStyle(isPinnedState ? .orange : .secondary)
            }.buttonStyle(.plain).help(isPinnedState ? "取消置顶（点击外部会隐藏）" : "置顶（点击外部不隐藏）")
            Button(action: { viewMode = viewMode == .list ? .grid : .list; UserDefaults.standard.set(viewMode.rawValue, forKey: "CollectionBox.viewMode") }) {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet").font(.system(size: 12))
            }.buttonStyle(.plain)
            Button(action: { newTabName = ""; isShowingNewTabAlert = true }) { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain)
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索", text: $searchText).textFieldStyle(.plain).font(.system(size: 12))
            if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain) }
            if sortOrder == .name { Button(action: { nameAscending.toggle() }) { Image(systemName: nameAscending ? "arrow.up" : "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain) }
            Menu { ForEach(SortOrder.allCases, id: \.self) { o in Button { sortOrder = o; UserDefaults.standard.set(o.rawValue, forKey: "CollectionBox.sortOrder") } label: { HStack { Text(o.label); if sortOrder == o { Image(systemName: "checkmark") } } } } }
            label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Entry Content

    @ViewBuilder
    private var entryContent: some View {
        if let tabID = selectedTabID, let ti = store.tabs.firstIndex(where: { $0.id == tabID }) {
            if store.tabs[ti].entries.isEmpty {
                emptyState.onDrop(of: [.fileURL], isTargeted: nil) { dropHandler(providers: $0, ti: ti) }
            } else {
                Group {
                    if viewMode == .list { sectionedList(ti: ti) } else { sectionedGrid(ti: ti) }
                }.onDrop(of: [.fileURL], isTargeted: nil) { dropHandler(providers: $0, ti: ti) }
            }
        } else { VStack { Spacer(); Text("点击 + 创建一个收藏夹").foregroundStyle(.secondary); Spacer() } }
    }

    // MARK: - List

    private func sectionedList(ti: Int) -> some View {
        List { ForEach(sections) { sec in
            if !sec.title.isEmpty {
                Section(header: Text(sec.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                    ForEach(sec.entries) { entry in listRow(entry: entry, ti: ti) }
                }
            } else {
                ForEach(sec.entries) { entry in listRow(entry: entry, ti: ti) }
            }
        }}.listStyle(.plain)
    }

    private func listRow(entry: BookmarkEntry, ti: Int) -> some View {
        EntryRow(entry: entry, isSelected: selectedEntryID == entry.id, isFlashing: flashID == entry.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openEntry(entry, ti: ti) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { withAnimation(.easeOut(duration: 0.05)) { selectedEntryID = entry.id } })
            .contextMenu { entryMenu(entry: entry, ti: ti) }
    }

    // MARK: - Grid

    private func sectionedGrid(ti: Int) -> some View {
        ScrollView { ForEach(sections) { sec in
            if !sec.title.isEmpty {
                HStack { Text(sec.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)], spacing: 12) {
                ForEach(sec.entries) { entry in
                    GridEntryItem(entry: entry, isSelected: selectedEntryID == entry.id, isFlashing: flashID == entry.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openEntry(entry, ti: ti) }
                        .simultaneousGesture(TapGesture(count: 1).onEnded { withAnimation(.easeOut(duration: 0.05)) { selectedEntryID = entry.id } })
                        .contextMenu { entryMenu(entry: entry, ti: ti) }
                }
            }.padding(.horizontal, 12).padding(.bottom, 4)
        }}
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func entryMenu(entry: BookmarkEntry, ti: Int) -> some View {
        Button { store.pinEntry(entry.id, in: ti) } label: {
            Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: entry.isPinned ? "pin.slash" : "pin")
        }
        Button("在 Finder 中显示") { showInFinder(entry.bookmarkData) }
        Divider()
        Button("移除", role: .destructive) { store.removeEntry(entry.id, from: ti); if selectedEntryID == entry.id { selectedEntryID = nil } }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) { Spacer()
            Image(systemName: "tray.and.arrow.down").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("拖拽文件到此处，收藏常用文件（夹）").font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer() }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ n: Notification) {
        guard let key = n.userInfo?["key"] as? String else { return }
        let entries = sortedEntries
        guard !entries.isEmpty else { return }
        switch key {
        case "up":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i > 0 { selectedEntryID = entries[i-1].id }
            else { selectedEntryID = entries.last?.id }
        case "down":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i < entries.count - 1 { selectedEntryID = entries[i+1].id }
            else { selectedEntryID = entries.first?.id }
        case "left":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i > 0 { selectedEntryID = entries[i-1].id }
            else { selectedEntryID = entries.last?.id }
        case "right":
            if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }), i < entries.count - 1 { selectedEntryID = entries[i+1].id }
            else { selectedEntryID = entries.first?.id }
        case "tab":
            if let cur = selectedTabID, let i = store.tabs.firstIndex(where: { $0.id == cur }) {
                let next = store.tabs[(i + 1) % store.tabs.count]
                selectedTabID = next.id
            }
        case "space", "return":
            if let id = selectedEntryID, let e = entries.first(where: { $0.id == id }), let ti = store.tabs.firstIndex(where: { $0.id == selectedTabID }) {
                openEntry(e, ti: ti)
            }
        case "escape":
            NotificationCenter.default.post(name: .panelShouldCollapse, object: nil)
        default: break
        }
    }

    // MARK: - Flash + Drop

    private func flash(_ id: UUID) { flashID = id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if flashID == id { flashID = nil } } }
    private func dropHandler(providers: [NSItemProvider], ti: Int) -> Bool {
        for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
            DispatchQueue.main.async { if let bd = try? BookmarkService.makeBookmark(for: url) { store.addEntry(BookmarkEntry(id: UUID(), displayName: url.lastPathComponent, bookmarkData: bd), to: ti) } }
        }}; return true
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("\(sortedEntries.count) 个项目").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(action: refreshCurrentTab) { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(.plain).help("刷新文件状态")
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func refreshCurrentTab() {
        guard let tabID = selectedTabID, let ti = store.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        store.refreshTab(ti)
    }

    // MARK: - Actions

    private func showInFinder(_ data: Data) {
        BookmarkService.withResolvedBookmark(data) { url in
            var isDir: ObjCBool = false; FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
    private func openEntry(_ entry: BookmarkEntry, ti: Int) {
        BookmarkService.withResolvedBookmark(entry.bookmarkData) { NSWorkspace.shared.open($0) }
        store.recordOpen(entry.id, in: ti); flash(entry.id)
    }
}

// MARK: - Notification

extension Notification.Name { static let collectionBoxKeyDown = Notification.Name("CollectionBoxKeyDown"); static let panelShouldCollapse = Notification.Name("PanelShouldCollapse") }

// MARK: - Entry Row (List)

struct EntryRow: View {
    let entry: BookmarkEntry
    var isSelected = false; var isFlashing = false
    var body: some View {
        HStack(spacing: 8) {
            FileIconView(fileName: entry.displayName).frame(width: 20, height: 20)
            Text(entry.displayName).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer()
        }.padding(.vertical, 3).padding(.horizontal, 6)
        .background(isFlashing ? Color.accentColor.opacity(0.10) : isSelected ? Color.accentColor.opacity(0.14) : Color.clear).cornerRadius(4)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isSelected = false; var isFlashing = false
    var body: some View {
        VStack(spacing: 4) {
            FileIconView(fileName: entry.displayName).frame(width: 40, height: 40).frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.08)).cornerRadius(8)
            Text(truncatedName).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).frame(width: 72, height: 28, alignment: .top)
        }.frame(width: 80, height: 100)
        .background(RoundedRectangle(cornerRadius: 6).fill(isFlashing ? Color.accentColor.opacity(0.10) : isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
    }
    /// Show ext + first few chars if name is long
    private var truncatedName: String {
        let name = entry.displayName
        let ext = (name as NSString).pathExtension
        if ext.isEmpty { return name }
        let base = (name as NSString).deletingPathExtension
        if base.count <= 10 { return name }
        return String(base.prefix(6)) + "…." + ext
    }
}

// MARK: - File Icon

struct FileIconView: View { let fileName: String; var body: some View { FileIconWrap(fileName: fileName) } }

#if canImport(AppKit)
struct FileIconWrap: NSViewRepresentable {
    let fileName: String
    func makeNSView(context: Context) -> NSImageView { let v = NSImageView(); v.imageScaling = .scaleProportionallyUpOrDown; v.image = icon(); return v }
    func updateNSView(_ v: NSImageView, context: Context) { v.image = icon() }
    private func icon() -> NSImage { let ext = (fileName as NSString).pathExtension; return ext.isEmpty ? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon))) : NSWorkspace.shared.icon(forFileType: ext) }
}
#else
struct FileIconWrap: View { let fileName: String; var body: some View { Image(systemName: "doc").font(.system(size: 24)) } }
#endif
