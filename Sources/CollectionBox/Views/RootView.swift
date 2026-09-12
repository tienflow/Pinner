import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import PDFKit

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

extension UTType {
    /// Internal drag type for reordering collection tabs.
    static let pinnerTab = UTType(exportedAs: "com.pinner.tab")
}

struct RootView: View {
    @State var store: CollectionStore
    var onPinToggle: (() -> Void)?
    var onQuickLook: (([UUID]) -> Void)?
    @State private var isPinnedState: Bool = false
    @State private var selectedTabID: UUID?
    @State private var isShowingNewTabAlert = false
    @State private var newTabName = ""
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var renamingEntryID: UUID?
    @State private var entryRenameText = ""
    @State private var searchText = ""
    @State private var selectedEntryID: UUID?
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var hoveredEntryID: UUID?
    @State private var flashID: UUID?
    @State private var nameAscending = true
    @State private var sortOrder: SortOrder = {
        SortOrder(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.sortOrder") ?? "date_added") ?? .dateAdded
    }()
    @State private var observerToken: NSObjectProtocol?
    @State private var viewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list") ?? .list
    }()
    @State private var gridColumns = 3
    @State private var isShowingImporter = false

    // MARK: - Derived Data

    private var currentTabIndex: Int? {
        selectedTabID.flatMap { id in store.tabs.firstIndex { $0.id == id } }
    }

    private var currentTab: CollectionTab? {
        currentTabIndex.map { store.tabs[$0] }
    }

    private var isSearching: Bool { !searchText.isEmpty }

    private var allFiltered: [BookmarkEntry] {
        guard let entries = currentTab?.entries else { return [] }
        return searchText.isEmpty ? entries : entries.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// Cross-tab search matches, current tab first, then the rest in tab order.
    private var searchMatches: [(entry: BookmarkEntry, tabIndex: Int)] {
        guard isSearching, let ci = currentTabIndex else { return [] }
        var out: [(BookmarkEntry, Int)] = []
        out += store.tabs[ci].entries.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }.map { ($0, ci) }
        for i in store.tabs.indices where i != ci {
            out += store.tabs[i].entries.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }.map { ($0, i) }
        }
        return out
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
        if isSearching {
            var byTab: [Int: [BookmarkEntry]] = [:]
            for m in searchMatches { byTab[m.tabIndex, default: []].append(m.entry) }
            return store.tabs.indices.compactMap { i in
                guard let entries = byTab[i], !entries.isEmpty else { return nil }
                return EntrySection(id: "tab_\(store.tabs[i].id)", title: store.tabs[i].name, entries: entries)
            }
        }
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

    /// Flat display order (pinned first, then sections) — the order the
    /// keyboard navigation follows.
    private var flatDisplay: [BookmarkEntry] {
        sections.flatMap(\.entries)
    }

    private func tabIndex(of entryID: UUID) -> Int? {
        store.tabs.firstIndex { tab in tab.entries.contains { $0.id == entryID } }
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
            if observerToken == nil {
                observerToken = NotificationCenter.default.addObserver(forName: .collectionBoxKeyDown, object: nil, queue: .main) { [self] in handleKeyDown($0) }
            }
        }
        .onDisappear {
            if let t = observerToken { NotificationCenter.default.removeObserver(t); observerToken = nil }
        }
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let ti = currentTabIndex else { return }
            store.addEntries(from: urls, to: ti)
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
        .alert("重命名条目", isPresented: .init(get: { renamingEntryID != nil }, set: { if !$0 { renamingEntryID = nil } })) {
            TextField("显示名称", text: $entryRenameText)
            Button("确认") {
                if let id = renamingEntryID, let ti = tabIndex(of: id) {
                    let n = entryRenameText.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { store.renameEntry(id, in: ti, to: n) }
                }
                renamingEntryID = nil
            }
            Button("取消", role: .cancel) { renamingEntryID = nil }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        tabButton(for: tab)
                            .onDrag { tabDragProvider(for: tab) }
                            .onDrop(of: [.pinnerTab], isTargeted: nil) { handleTabDrop(providers: $0, onto: tab) }
                    }
                }
            }
            .layoutPriority(1)
            Button(action: { onPinToggle?(); isPinnedState.toggle() }) {
                Image(systemName: isPinnedState ? "pin.fill" : "pin.slash").font(.system(size: 12)).foregroundStyle(isPinnedState ? .orange : .secondary)
            }.buttonStyle(.plain).fixedSize()
                .help(isPinnedState ? "取消置顶（点击外部会隐藏）" : "置顶（点击外部不隐藏）")
                .accessibilityLabel(isPinnedState ? "取消置顶面板" : "置顶面板")
            Button(action: { viewMode = viewMode == .list ? .grid : .list; UserDefaults.standard.set(viewMode.rawValue, forKey: "CollectionBox.viewMode") }) {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet").font(.system(size: 12))
            }.buttonStyle(.plain).fixedSize()
                .help(viewMode == .list ? "切换到宫格视图" : "切换到列表视图")
                .accessibilityLabel(viewMode == .list ? "切换到宫格视图" : "切换到列表视图")
            Button(action: { newTabName = ""; isShowingNewTabAlert = true }) { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).fixedSize()
                .help("新建收藏夹").accessibilityLabel("新建收藏夹")
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func tabButton(for tab: CollectionTab) -> some View {
        Button(action: { selectTab(tab.id) }) {
            Text(tab.name).font(.system(size: 12, weight: tab.id == selectedTabID ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(tab.id == selectedTabID ? Color.accentColor.opacity(0.15) : Color.clear).cornerRadius(4)
        }.buttonStyle(.plain).contextMenu {
            Button("重命名") { renameText = tab.name; renamingTabID = tab.id }; Divider()
            Button("删除", role: .destructive) { if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) { store.deleteTab(at: i); if selectedTabID == tab.id { selectedTabID = store.tabs.first?.id }; clearSelection() } }
        }
    }

    private func selectTab(_ id: UUID) {
        selectedTabID = id
        clearSelection()
    }

    private func tabDragProvider(for tab: CollectionTab) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = tab.id.uuidString.data(using: .utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pinnerTab.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func handleTabDrop(providers: [NSItemProvider], onto tab: CollectionTab) -> Bool {
        guard let p = providers.first else { return false }
        p.loadItem(forTypeIdentifier: UTType.pinnerTab.identifier, options: nil) { item, _ in
            let str: String?
            if let s = item as? String { str = s }
            else if let d = item as? Data { str = String(data: d, encoding: .utf8) }
            else { str = nil }
            guard let idStr = str, let id = UUID(uuidString: idStr) else { return }
            DispatchQueue.main.async {
                guard let src = store.tabs.firstIndex(where: { $0.id == id }),
                      let dst = store.tabs.firstIndex(where: { $0.id == tab.id }), src != dst else { return }
                store.moveTab(from: src, to: dst)
            }
        }
        return true
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("搜索", text: $searchText).textFieldStyle(.plain).font(.system(size: 12))
            if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索") }
            if sortOrder == .name && !isSearching { Button(action: { nameAscending.toggle() }) { Image(systemName: nameAscending ? "arrow.up" : "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("切换名称排序方向").accessibilityLabel("切换名称排序方向") }
            Menu { ForEach(SortOrder.allCases, id: \.self) { o in Button { sortOrder = o; UserDefaults.standard.set(o.rawValue, forKey: "CollectionBox.sortOrder") } label: { HStack { Text(o.label); if sortOrder == o { Image(systemName: "checkmark") } } } } }
            label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("排序方式")
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - Entry Content

    @ViewBuilder
    private var entryContent: some View {
        if let ti = currentTabIndex {
            if store.tabs[ti].entries.isEmpty && !isSearching {
                emptyState.onDrop(of: [.fileURL], isTargeted: nil) { dropHandler(providers: $0, ti: ti) }
            } else if isSearching && flatDisplay.isEmpty {
                VStack { Spacer(); Text("所有收藏夹中都没有匹配“\(searchText)”的文件").font(.system(size: 13)).foregroundStyle(.secondary); Spacer() }
            } else {
                ScrollViewReader { proxy in
                    Group {
                        if viewMode == .list { sectionedList() } else { sectionedGrid() }
                    }
                    .onChange(of: selectedEntryID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { dropHandler(providers: $0, ti: ti) }
            }
        } else { VStack { Spacer(); Text("点击 + 创建一个收藏夹").foregroundStyle(.secondary); Spacer() } }
    }

    // MARK: - List

    private func sectionedList() -> some View {
        List { ForEach(sections) { sec in
            if !sec.title.isEmpty {
                Section(header: Text(sec.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)) {
                    ForEach(sec.entries) { entry in listRow(entry) }
                }
            } else {
                ForEach(sec.entries) { entry in listRow(entry) }
            }
        }}.listStyle(.plain)
    }

    private func listRow(_ entry: BookmarkEntry) -> some View {
        EntryRow(entry: entry, isSelected: isRowSelected(entry), isFlashing: flashID == entry.id, isHovered: hoveredEntryID == entry.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openEntry(entry) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { handleRowTap(entry) })
            .contextMenu { entryMenu(entry) }
            .onDrag { dragProvider(for: entry) }
            .onHover { hovering in
                if hovering { hoveredEntryID = entry.id }
                else if hoveredEntryID == entry.id { hoveredEntryID = nil }
            }
            .id(entry.id)
    }

    // MARK: - Grid

    private func sectionedGrid() -> some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 24) / 92))
            ScrollView { ForEach(sections) { sec in
                if !sec.title.isEmpty {
                    HStack { Text(sec.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)], spacing: 12) {
                    ForEach(sec.entries) { entry in
                        GridEntryItem(entry: entry, isSelected: isRowSelected(entry), isFlashing: flashID == entry.id, isHovered: hoveredEntryID == entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { openEntry(entry) }
                            .simultaneousGesture(TapGesture(count: 1).onEnded { handleRowTap(entry) })
                            .contextMenu { entryMenu(entry) }
                            .onDrag { dragProvider(for: entry) }
                            .onHover { hovering in
                                if hovering { hoveredEntryID = entry.id }
                                else if hoveredEntryID == entry.id { hoveredEntryID = nil }
                            }
                            .id(entry.id)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 4)
            }}
            .onAppear { gridColumns = cols }
            .onChange(of: geo.size.width) { _, _ in gridColumns = cols }
        }
    }

    // MARK: - Selection

    private func isRowSelected(_ entry: BookmarkEntry) -> Bool {
        selectedEntryIDs.contains(entry.id) || selectedEntryID == entry.id
    }

    private func handleRowTap(_ entry: BookmarkEntry) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            if selectedEntryIDs.contains(entry.id) { selectedEntryIDs.remove(entry.id) } else { selectedEntryIDs.insert(entry.id) }
            selectionAnchor = entry.id
        } else if mods.contains(.shift), let anchor = selectionAnchor ?? selectedEntryID,
                  let ai = flatDisplay.firstIndex(where: { $0.id == anchor }),
                  let ci = flatDisplay.firstIndex(where: { $0.id == entry.id }) {
            let range = ai < ci ? ai...ci : ci...ai
            selectedEntryIDs = Set(flatDisplay[range].map(\.id))
        } else {
            selectedEntryIDs = [entry.id]
            selectionAnchor = entry.id
        }
        selectedEntryID = entry.id
    }

    private var orderedSelectedIDs: [UUID] {
        flatDisplay.map(\.id).filter { selectedEntryIDs.contains($0) }
    }

    /// Multi-selection for context-menu actions when the right-clicked entry
    /// is part of it; single-entry list otherwise.
    private func batchSelection(containing entry: BookmarkEntry) -> [UUID] {
        (selectedEntryIDs.contains(entry.id) && selectedEntryIDs.count > 1) ? orderedSelectedIDs : [entry.id]
    }

    private func clearSelection() {
        selectedEntryIDs = []
        selectedEntryID = nil
        selectionAnchor = nil
    }

    private func pruneSelection() {
        let valid = Set(store.tabs.flatMap { $0.entries.map(\.id) })
        selectedEntryIDs = selectedEntryIDs.intersection(valid)
        if let id = selectedEntryID, !valid.contains(id) { selectedEntryID = nil }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func entryMenu(_ entry: BookmarkEntry) -> some View {
        let ids = batchSelection(containing: entry)
        if ids.count > 1 {
            Menu("移动 \(ids.count) 项到…") {
                ForEach(Array(store.tabs.enumerated()), id: \.element.id) { dstIndex, dstTab in
                    Button(dstTab.name) { store.moveEntries(ids, to: dstIndex) }
                }
            }
            Button("移除 \(ids.count) 项", role: .destructive) {
                store.removeEntriesGlobally(ids)
                pruneSelection()
            }
        } else if let ti = tabIndex(of: entry.id) {
            Button { store.pinEntry(entry.id, in: ti) } label: {
                Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            Button { onQuickLook?([entry.id]) } label: {
                Label("快速预览", systemImage: "eye")
            }.keyboardShortcut("y", modifiers: .command)
            Button { copyPath(entry) } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            Button { openInTerminal(entry) } label: {
                Label("在终端中打开", systemImage: "terminal")
            }
            Button("在 Finder 中显示") { showInFinder(entry.bookmarkData) }
            if store.tabs.count > 1 {
                Divider()
                Menu("移动到…") {
                    ForEach(Array(store.tabs.enumerated()), id: \.element.id) { dstIndex, dstTab in
                        if dstIndex != ti {
                            Button(dstTab.name) {
                                store.moveEntry(entry.id, from: ti, to: dstIndex)
                            }
                        }
                    }
                }
            }
            Button("重命名") { entryRenameText = entry.displayName; renamingEntryID = entry.id }
            Divider()
            Button("移除", role: .destructive) {
                store.removeEntry(entry.id, from: ti)
                pruneSelection()
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) { Spacer()
            Image(systemName: "tray.and.arrow.down").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("拖拽文件到此处，或点击下方 + 添加").font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer() }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ n: Notification) {
        guard let key = n.userInfo?["key"] as? String else { return }
        switch key {
        case "tab", "shiftTab":
            if let cur = selectedTabID, let i = store.tabs.firstIndex(where: { $0.id == cur }) {
                let next = key == "tab" ? (i + 1) % store.tabs.count : (i - 1 + store.tabs.count) % store.tabs.count
                selectTab(store.tabs[next].id)
            }
            return
        case "escape":
            NotificationCenter.default.post(name: .panelShouldCollapse, object: nil)
            return
        case "undo":
            if store.undo() { pruneSelection() }
            return
        case "quicklook":
            let ids = selectedEntryIDs.isEmpty ? (selectedEntryID.map { [$0] } ?? []) : orderedSelectedIDs
            if !ids.isEmpty { onQuickLook?(ids) }
            return
        case "delete":
            let ids = orderedSelectedIDs
            if !ids.isEmpty {
                store.removeEntriesGlobally(ids)
                pruneSelection()
            }
            return
        default: break
        }
        let entries = flatDisplay
        guard !entries.isEmpty else { return }
        switch key {
        case "up": moveSelection(-1, in: entries)
        case "down": moveSelection(1, in: entries)
        case "left": moveSelection(viewMode == .grid ? -max(1, gridColumns) : -1, in: entries)
        case "right": moveSelection(viewMode == .grid ? max(1, gridColumns) : 1, in: entries)
        case "space", "return":
            if let id = selectedEntryID, let e = entries.first(where: { $0.id == id }) {
                openEntry(e)
            }
        default: break
        }
    }

    private func moveSelection(_ delta: Int, in entries: [BookmarkEntry]) {
        let next: Int
        if let cur = selectedEntryID, let i = entries.firstIndex(where: { $0.id == cur }) {
            next = min(max(i + delta, 0), entries.count - 1)
        } else {
            next = delta < 0 ? entries.count - 1 : 0
        }
        selectedEntryID = entries[next].id
        selectedEntryIDs = [entries[next].id]
        selectionAnchor = selectedEntryID
    }

    // MARK: - Flash + Drop

    private func flash(_ id: UUID) { flashID = id; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if flashID == id { flashID = nil } } }

    private func dropHandler(providers: [NSItemProvider], ti: Int) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) {
            store.addEntries(from: urls, to: ti)
        }
        return true
    }

    private func dragProvider(for entry: BookmarkEntry) -> NSItemProvider {
        guard let url = BookmarkService.resolveURL(entry.bookmarkData) else { return NSItemProvider() }
        return NSItemProvider(object: url as NSURL)
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var countText: some View {
        if isSearching {
            Text("\(flatDisplay.count) 个结果")
        } else {
            let missing = currentTab?.entries.filter(\.isMissing).count ?? 0
            if missing > 0 {
                Text("\(currentTab?.entries.count ?? 0) 个项目 · \(missing) 个未找到")
            } else {
                Text("\(currentTab?.entries.count ?? 0) 个项目")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            countText.font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(action: { isShowingImporter = true }) { Image(systemName: "folder.badge.plus").font(.system(size: 11)) }
                .buttonStyle(.plain).help("添加文件或文件夹").accessibilityLabel("添加文件或文件夹")
            Button(action: refreshCurrentTab) { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                .buttonStyle(.plain).help("刷新文件状态").accessibilityLabel("刷新文件状态")
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func refreshCurrentTab() {
        guard let ti = currentTabIndex else { return }
        Task { await store.refreshTabAsync(ti) }
    }

    // MARK: - Actions

    private func showInFinder(_ data: Data) {
        BookmarkService.withResolvedBookmark(data) { url in
            var isDir: ObjCBool = false; FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func copyPath(_ entry: BookmarkEntry) {
        guard let path = BookmarkService.resolvedPath(entry.bookmarkData) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func openInTerminal(_ entry: BookmarkEntry) {
        BookmarkService.withResolvedBookmark(entry.bookmarkData) { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let target = isDir.boolValue ? url : url.deletingLastPathComponent()
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func openEntry(_ entry: BookmarkEntry) {
        guard let ti = tabIndex(of: entry.id) else { return }
        BookmarkService.withResolvedBookmark(entry.bookmarkData) { NSWorkspace.shared.open($0) }
        store.recordOpen(entry.id, in: ti); flash(entry.id)
    }
}

// MARK: - Notification

extension Notification.Name { static let collectionBoxKeyDown = Notification.Name("CollectionBoxKeyDown"); static let panelShouldCollapse = Notification.Name("PanelShouldCollapse") }

// MARK: - Entry Row (List)

struct EntryRow: View {
    let entry: BookmarkEntry
    var isSelected = false; var isFlashing = false; var isHovered = false
    var body: some View {
        HStack(spacing: 8) {
            FileIconView(entry: entry).frame(width: 20, height: 20).opacity(entry.isMissing ? 0.4 : 1)
            Text(entry.displayName).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
            if entry.isMissing {
                Text("未找到").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
        }.padding(.vertical, 3).padding(.horizontal, 6)
        .background(isFlashing ? Color.accentColor.opacity(0.10) : isSelected ? Color.accentColor.opacity(0.14) : isHovered ? Color.secondary.opacity(0.06) : Color.clear).cornerRadius(4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isSelected = false; var isFlashing = false; var isHovered = false
    var body: some View {
        VStack(spacing: 4) {
            FileIconView(entry: entry).frame(width: 40, height: 40).frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.08)).cornerRadius(8)
                .overlay(alignment: .topTrailing) {
                    if entry.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            .offset(x: 3, y: -3)
                    }
                }
            Text(truncatedName).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
                .frame(width: 72, height: 28, alignment: .top)
        }.frame(width: 80, height: 100)
        .background(RoundedRectangle(cornerRadius: 6).fill(isFlashing ? Color.accentColor.opacity(0.10) : isSelected ? Color.accentColor.opacity(0.14) : isHovered ? Color.secondary.opacity(0.06) : Color.clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
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

struct FileIconView: View { let entry: BookmarkEntry; var body: some View { FileIconWrap(entry: entry) } }

#if canImport(AppKit)
struct FileIconWrap: NSViewRepresentable {
    let entry: BookmarkEntry
    static let iconCache = NSCache<NSString, NSImage>()
    private static let thumbnailableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "pdf"]

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(); v.imageScaling = .scaleProportionallyUpOrDown
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        v.image = Self.baseIcon(for: entry)
        Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
            if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
        }
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        v.image = Self.baseIcon(for: entry)
        Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
            if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
        }
    }

    static func baseIcon(for entry: BookmarkEntry) -> NSImage {
        let ext = (entry.displayName as NSString).pathExtension
        let fallback = ext.isEmpty
            ? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
            : NSWorkspace.shared.icon(forFileType: ext)
        guard let url = BookmarkService.resolveURL(entry.bookmarkData) else { return fallback }
        let key = url.standardizedFileURL.path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Decodes an image/PDF thumbnail off the main thread and caches it by path.
    static func loadThumbnailIfAvailable(for entry: BookmarkEntry, completion: @escaping (NSImage) -> Void) {
        let ext = (entry.displayName as NSString).pathExtension.lowercased()
        guard thumbnailableExtensions.contains(ext),
              let url = BookmarkService.resolveURL(entry.bookmarkData) else { return }
        let pathKey = url.standardizedFileURL.path as NSString
        if let cached = iconCache.object(forKey: pathKey) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let thumb = Self.thumbnail(at: url.path, ext: ext, maxPixel: 256) else { return }
            iconCache.setObject(thumb, forKey: pathKey)
            DispatchQueue.main.async { completion(thumb) }
        }
    }

    static func thumbnail(at path: String, ext: String, maxPixel: Int) -> NSImage? {
        if ext == "pdf" {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
                  let page = doc.page(at: 0) else { return nil }
            let thumb = page.thumbnail(of: CGSize(width: maxPixel, height: maxPixel), for: .mediaBox)
            return thumb
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
#else
struct FileIconWrap: View { let entry: BookmarkEntry; var body: some View { Image(systemName: "doc").font(.system(size: 24)) } }
#endif
