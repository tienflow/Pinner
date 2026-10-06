import SwiftUI
import UniformTypeIdentifiers
import ImageIO
import PDFKit
import QuickLookThumbnailing

enum ViewMode: String, CaseIterable { case list, grid }
enum SortOrder: String, CaseIterable {
    case manual = "manual"
    case name = "name"
    case dateAdded = "date_added"
    case lastOpened = "last_opened"
    case type = "type"
    var label: String {
        switch self {
        case .manual: return "自定义"
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
    /// Internal drag type for reordering entries within a tab.
    static let pinnerEntry = UTType(exportedAs: "com.pinner.entry")
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
    @State private var flashID: UUID?
    @State private var actionMessage: String?
    @State private var nameAscending = true
    @State private var sortOrder: SortOrder = {
        SortOrder(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.sortOrder") ?? "date_added") ?? .dateAdded
    }()
    @State private var observerToken: NSObjectProtocol?
    @State private var viewMode: ViewMode = {
        ViewMode(rawValue: UserDefaults.standard.string(forKey: "CollectionBox.viewMode") ?? "list") ?? .list
    }()
    @AppStorage("CollectionBox.shelfTrashOriginalOnDragOut")
    private var shelfTrashOriginalOnDragOut: Bool = false
    @State private var gridColumns = 3
    @State private var isShowingImporter = false
    @State private var dropTargeted = false
    /// Cross-tab "最近访问" mode: shows recently opened entries from every tab
    /// instead of a single tab's content.
    @State private var showingRecents = false
    /// Temporary Drop Shelf mode: a scratchpad for files to drop in and drag out.
    @State private var showingShelf = false
    @State private var isShelfTabTargeted = false
    @State private var isShelfContentTargeted = false

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
        return searchText.isEmpty ? entries : entries.filter { PinyinMatcher.matches(query: searchText, in: $0.displayName) }
    }

    /// Cross-tab search matches, current tab first, then the rest in tab order.
    private var searchMatches: [(entry: BookmarkEntry, tabIndex: Int)] {
        guard isSearching, let ci = currentTabIndex else { return [] }
        var out: [(BookmarkEntry, Int)] = []
        out += store.tabs[ci].entries.filter { PinyinMatcher.matches(query: searchText, in: $0.displayName) }.map { ($0, ci) }
        for i in store.tabs.indices where i != ci {
            out += store.tabs[i].entries.filter { PinyinMatcher.matches(query: searchText, in: $0.displayName) }.map { ($0, i) }
        }
        return out
    }

    private var pinnedEntries: [BookmarkEntry] {
        let pinned = allFiltered.filter { $0.isPinned }
        // Manual order preserves the stored array order; other modes sort by name.
        guard sortOrder != .manual else { return pinned }
        return pinned.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var sortedEntries: [BookmarkEntry] {
        let unpinned = allFiltered.filter { !$0.isPinned }
        switch sortOrder {
        case .manual: return unpinned
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
        if showingShelf {
            return [EntrySection(id: "shelf", title: "", entries: store.shelfEntries)]
        }
        if showingRecents {
            let pairs = store.recentEntries().compactMap { re in re.entry.lastOpened.map { (re.entry, $0) } }
            return groupByDate(pairs)
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
            topBar; tabBar; Divider().opacity(0.35); searchBar; Divider().opacity(0.35); entryContent; Divider().opacity(0.35); bottomBar
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 400)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
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
        .onChange(of: isShelfContentTargeted) { _, targeted in
            if targeted { Haptics.light() }
        }
        .onChange(of: isShelfTabTargeted) { _, targeted in
            if targeted { Haptics.light() }
        }
        .onChange(of: dropTargeted) { _, targeted in
            if targeted { Haptics.light() }
        }
    }

    // MARK: - Top Window Control Bar & Tab Bar

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer()
            Button(action: { onPinToggle?(); isPinnedState.toggle() }) {
                Image(systemName: isPinnedState ? "pin.fill" : "pin.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isPinnedState ? .orange : .secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize()
                .help(isPinnedState ? "取消置顶（点击外部会隐藏）" : "置顶（点击外部不隐藏）")
                .accessibilityLabel(isPinnedState ? "取消置顶面板" : "置顶面板")

            Button(action: { viewMode = viewMode == .list ? .grid : .list; UserDefaults.standard.set(viewMode.rawValue, forKey: "CollectionBox.viewMode") }) {
                Image(systemName: viewMode == .list ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize()
                .help(viewMode == .list ? "切换到宫格视图" : "切换到列表视图")
                .accessibilityLabel(viewMode == .list ? "切换到宫格视图" : "切换到列表视图")

            Button(action: { newTabName = ""; isShowingNewTabAlert = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize()
                .help("新建收藏夹").accessibilityLabel("新建收藏夹")
        }
        .frame(height: 26)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            // 固定"最近访问"入口，独立于收藏夹 Tab
            Button(action: { showingRecents = true; showingShelf = false; clearSelection() }) {
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 11, weight: .medium))
                    Text("最近").font(.system(size: Design.ui, weight: showingRecents ? .semibold : .regular))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(showingRecents ? Color.accentColor.opacity(Design.selectedAlpha) : Color.clear, in: Capsule())
                .foregroundStyle(showingRecents ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).fixedSize()
            .help("跨收藏夹查看最近打开的文件")
            .accessibilityLabel("最近访问")

            // 固定"暂存"入口（中转架）
            Button(action: { showingShelf = true; showingRecents = false; clearSelection() }) {
                HStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 11, weight: .medium))
                    Text(store.shelfEntries.isEmpty ? "暂存" : "暂存 \(store.shelfEntries.count)")
                        .font(.system(size: Design.ui, weight: showingShelf ? .semibold : .regular))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    isShelfTabTargeted
                        ? Color.accentColor.opacity(0.35)
                        : (showingShelf ? Color.accentColor.opacity(Design.selectedAlpha) : Color.clear),
                    in: Capsule()
                )
                .foregroundStyle(showingShelf ? Color.accentColor : Color.secondary)
                .overlay(
                    Capsule().strokeBorder(isShelfTabTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain).fixedSize()
            .help("临时文件暂存中转架，拖入暂存，随时拖到其他窗口")
            .accessibilityLabel("临时暂存中转架")
            .onDrop(of: [.fileURL], isTargeted: $isShelfTabTargeted) { handleShelfDrop(providers: $0) }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        tabButton(for: tab)
                            .onDrag { tabDragProvider(for: tab) }
                            .onDrop(of: [.pinnerTab], isTargeted: nil) { handleTabDrop(providers: $0, onto: tab) }
                    }
                }
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }

    private func tabButton(for tab: CollectionTab) -> some View {
        Button(action: { selectTab(tab.id) }) {
            Text(tab.name).font(.system(size: Design.ui, weight: tab.id == selectedTabID ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(tab.id == selectedTabID ? Color.accentColor.opacity(Design.selectedAlpha) : Color.clear, in: Capsule())
        }.buttonStyle(.plain).contextMenu {
            Button("重命名") { renameText = tab.name; renamingTabID = tab.id }; Divider()
            Button("删除", role: .destructive) { if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) { store.deleteTab(at: i); if selectedTabID == tab.id { selectedTabID = store.tabs.first?.id }; clearSelection() } }
        }
    }

    private func selectTab(_ id: UUID) {
        selectedTabID = id
        showingRecents = false
        showingShelf = false
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
            TextField("搜索", text: $searchText).textFieldStyle(.plain).font(.system(size: Design.body))
            if !searchText.isEmpty { Button(action: { searchText = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索") }
            if sortOrder == .name && !isSearching { Button(action: { nameAscending.toggle() }) { Image(systemName: nameAscending ? "arrow.up" : "arrow.down").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("切换名称排序方向").accessibilityLabel("切换名称排序方向") }
            Menu { ForEach(SortOrder.allCases, id: \.self) { o in Button { sortOrder = o; UserDefaults.standard.set(o.rawValue, forKey: "CollectionBox.sortOrder") } label: { HStack { Text(o.label); if sortOrder == o { Image(systemName: "checkmark") } } } } }
            label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("排序方式")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .liquidGlassCard(cornerRadius: Design.radiusM)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    // MARK: - Entry Content

    @ViewBuilder
    private var entryContent: some View {
        if showingShelf && !isSearching {
            if store.shelfEntries.isEmpty {
                shelfEmptyState.onDrop(of: [.fileURL], isTargeted: $dropTargeted) { handleShelfDrop(providers: $0) }
            } else {
                VStack(spacing: 0) {
                    shelfHeader
                    Divider()
                    if isShelfContentTargeted {
                        shelfDropSlot
                    }
                    ScrollViewReader { proxy in
                        Group {
                            if viewMode == .list { sectionedList() } else { sectionedGrid() }
                        }
                        .onChange(of: selectedEntryID) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .overlay(
                    Group {
                        if isShelfContentTargeted {
                            RoundedRectangle(cornerRadius: Design.radiusM)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(4)
                        }
                    }
                )
                .onDrop(of: [.fileURL], isTargeted: $isShelfContentTargeted) { handleShelfDrop(providers: $0) }
                .animation(.easeInOut(duration: 0.15), value: isShelfContentTargeted)
            }
        } else if showingRecents && !isSearching {
            if store.recentEntries().isEmpty {
                recentsEmptyState
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
            }
        } else if let ti = currentTabIndex {
            if store.tabs[ti].entries.isEmpty && !isSearching {
                emptyState.onDrop(of: [.fileURL], isTargeted: $dropTargeted) { dropHandler(providers: $0, ti: ti) }
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

    private var shelfEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: dropTargeted ? "shippingbox.fill" : "shippingbox")
                .font(.system(size: 34))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .scaleEffect(dropTargeted ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropTargeted)
            Text(dropTargeted ? "松开以暂存文件" : "拖入文件即可暂存")
                .font(.system(size: Design.body, weight: .semibold))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            Text(shelfTrashOriginalOnDragOut ? "跨窗口中转 · 拖出自动剪切" : "跨窗口中转 · 拖出即用")
                .font(.system(size: Design.caption))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: dropTargeted ? [6, 3] : [5, 3])
                )
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                .padding(6)
        )
        .padding(6)
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
    }

    private var shelfDropSlot: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 12))
            Text("松开以添加至暂存架")
                .font(.system(size: Design.caption, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusS)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var shelfHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(store.shelfEntries.count) 个临时文件")
                    .font(.system(size: Design.caption))
                    .foregroundStyle(.secondary)
                Spacer()

                // 移动全部到… 按钮
                Button(action: {
                    let allIDs = store.shelfEntries.map(\.id)
                    moveShelfEntriesToFolder(allIDs)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("移动全部到…")
                            .font(.system(size: Design.caption))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("选择目标文件夹，将暂存架内所有文件物理移动过去并清空暂存")

                // 全部拖出按钮
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                    Text("全部拖出")
                        .font(.system(size: Design.caption, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
                .onDrag { dragAllShelfProvider() }
                .help(shelfTrashOriginalOnDragOut
                    ? "按住并拖出全部文件（外部接收后自动移入废纸篓完成物理剪切）"
                    : "按住并拖出全部文件（拖出后自动从暂存架移除）")

                Button(action: {
                    store.clearShelf()
                    clearSelection()
                }) {
                    Text("清空")
                        .font(.system(size: Design.caption))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help("清空暂存架")
            }

            HStack(spacing: 4) {
                Image(systemName: shelfTrashOriginalOnDragOut ? "scissors" : "info.circle")
                    .font(.system(size: 9))
                Text(shelfTrashOriginalOnDragOut
                    ? "物理剪切模式生效中 · 拖出后源文件自动移入废纸篓"
                    : "拖出后自动移除暂存 · 偏好设置中可开启物理剪切")
                    .font(.system(size: 10))
            }
            .foregroundStyle(shelfTrashOriginalOnDragOut ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private var recentsEmptyState: some View {
        VStack(spacing: 8) { Spacer()
            Image(systemName: "clock").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("最近打开的文件会显示在这里").font(.system(size: Design.body)).foregroundStyle(.secondary)
        Spacer() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private func sectionedList() -> some View {
        List { ForEach(sections) { sec in
            if !sec.title.isEmpty {
                Section(header: Text(sec.title).font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)) {
                    ForEach(sec.entries) { entry in listRow(entry) }
                }
            } else {
                ForEach(sec.entries) { entry in listRow(entry) }
            }
        }}
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func listRow(_ entry: BookmarkEntry) -> some View {
        EntryRow(entry: entry, isSelected: isRowSelected(entry), isFlashing: flashID == entry.id,
                 sourceLabel: showingRecents ? sourceTabName(for: entry) : nil,
                 onRemove: showingShelf ? { store.removeShelfEntry(entry.id); pruneSelection() } : nil,
                 onReorderDrop: { handleEntryReorderDrop(providers: $0, onto: entry) })
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openEntry(entry) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { handleRowTap(entry) })
            .contextMenu { entryMenu(entry) }
            .onDrag { dragProvider(for: entry) }
            .id(entry.id)
    }

    /// Source tab display name for cross-tab views (recents).
    private func sourceTabName(for entry: BookmarkEntry) -> String? {
        guard let ti = tabIndex(of: entry.id), store.tabs.indices.contains(ti) else { return nil }
        return store.tabs[ti].name
    }

    // MARK: - Grid

    private func sectionedGrid() -> some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 24) / 92))
            ScrollView { ForEach(sections) { sec in
                if !sec.title.isEmpty {
                    HStack { Text(sec.title).font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary); Spacer() }.padding(.horizontal, 12).padding(.top, 8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)], spacing: 12) {
                    ForEach(sec.entries) { entry in
                        gridCell(entry)
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

    private func gridCell(_ entry: BookmarkEntry) -> some View {
        GridEntryItem(entry: entry, isSelected: isRowSelected(entry), isFlashing: flashID == entry.id,
                      onRemove: showingShelf ? { store.removeShelfEntry(entry.id); pruneSelection() } : nil,
                      onReorderDrop: { handleEntryReorderDrop(providers: $0, onto: entry) })
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openEntry(entry) }
            .simultaneousGesture(TapGesture(count: 1).onEnded { handleRowTap(entry) })
            .contextMenu { entryMenu(entry) }
            .onDrag { dragProvider(for: entry) }
            .id(entry.id)
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
        let valid = showingShelf
            ? Set(store.shelfEntries.map(\.id))
            : Set(store.tabs.flatMap { $0.entries.map(\.id) })
        selectedEntryIDs = selectedEntryIDs.intersection(valid)
        if let id = selectedEntryID, !valid.contains(id) { selectedEntryID = nil }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func entryMenu(_ entry: BookmarkEntry) -> some View {
        let ids = batchSelection(containing: entry)
        if showingShelf {
            Button { onQuickLook?(ids) } label: {
                Label("快速预览", systemImage: "eye")
            }.keyboardShortcut("y", modifiers: .command)
            Button { copyPath(entry) } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            Button { openInTerminal(entry) } label: {
                Label("在终端中打开", systemImage: "terminal")
            }
            Button("在 Finder 中显示") { showInFinder(entry.bookmarkData) }
            Divider()
            Button {
                moveShelfEntriesToFolder(ids)
            } label: {
                Label(ids.count > 1 ? "移动 \(ids.count) 项到…" : "移动到…", systemImage: "folder")
            }
            if !store.tabs.isEmpty {
                Menu(ids.count > 1 ? "转存 \(ids.count) 项至收藏夹…" : "转存至收藏夹…") {
                    ForEach(Array(store.tabs.enumerated()), id: \.element.id) { tabIdx, tab in
                        Button(tab.name) {
                            saveShelfEntriesToTab(ids, tabIndex: tabIdx)
                        }
                    }
                }
            }
            Divider()
            Button(ids.count > 1 ? "从暂存架移除 \(ids.count) 项" : "从暂存架移除", role: .destructive) {
                store.removeShelfEntries(ids)
                pruneSelection()
            }
        } else if ids.count > 1 {
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
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 32))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .scaleEffect(dropTargeted ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropTargeted)
            Text(dropTargeted ? "松开以添加到收藏" : "拖拽文件到此处收藏，或点击下方 +")
                .font(.system(size: Design.body, weight: dropTargeted ? .semibold : .regular))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1.5, dash: dropTargeted ? [6, 3] : [5, 3])
                )
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                .padding(6)
        )
        .padding(6)
        .animation(.easeInOut(duration: 0.15), value: dropTargeted)
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
                if showingShelf {
                    store.removeShelfEntries(ids)
                } else {
                    store.removeEntriesGlobally(ids)
                }
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
        case "space":
            let ids = selectedEntryIDs.isEmpty ? (selectedEntryID.map { [$0] } ?? []) : orderedSelectedIDs
            if !ids.isEmpty { onQuickLook?(ids) }
        case "return":
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
        NotificationCenter.default.post(name: .quickLookSelectionDidChange, object: nil, userInfo: ["ids": [entries[next].id]])
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

    private func handleShelfDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            store.addShelfEntries(from: urls)
            Haptics.success()
        }
        return true
    }

    private func dragAllShelfProvider() -> NSItemProvider {
        let pairs: [(URL, UUID)] = store.shelfEntries.compactMap { entry in
            guard let url = BookmarkService.resolveURL(entry.bookmarkData) else { return nil }
            return (url, entry.id)
        }
        guard let first = pairs.first else { return NSItemProvider() }
        let firstItem = ShelfFileNSURL(fileURL: first.0, entryIDs: [first.1]) { [weak store] ids, url in
            handleShelfItemConsumed(entryIDs: ids, fileURL: url)
        }
        let provider = NSItemProvider(object: firstItem)
        if pairs.count > 1 {
            let paths = pairs.map { $0.0.path }
            let pboardType = "NSFilenamesPboardType"
            if let plistData = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                provider.registerDataRepresentation(forTypeIdentifier: pboardType, visibility: .all) { completion in
                    completion(plistData, nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak store] in
                        for pair in pairs {
                            self.handleShelfItemConsumed(entryIDs: [pair.1], fileURL: pair.0)
                        }
                    }
                    return nil
                }
            }
        }
        return provider
    }

    /// Entries drag with multiple representations: a file URL (drag out to
    /// other apps), an internal entry ID data blob, and a plain-text ID
    /// fallback (some pasteboard matching paths only surface text types).
    private func dragProvider(for entry: BookmarkEntry) -> NSItemProvider {
        var provider = NSItemProvider()
        if showingShelf {
            let targetEntries: [BookmarkEntry]
            if selectedEntryIDs.contains(entry.id) && selectedEntryIDs.count > 1 {
                let selectedSet = selectedEntryIDs
                targetEntries = store.shelfEntries.filter { selectedSet.contains($0.id) }
            } else {
                targetEntries = [entry]
            }

            let pairs: [(URL, UUID)] = targetEntries.compactMap { e in
                guard let url = BookmarkService.resolveURL(e.bookmarkData) else { return nil }
                return (url, e.id)
            }

            if let first = pairs.first {
                let firstItem = ShelfFileNSURL(fileURL: first.0, entryIDs: [first.1]) { [weak store] ids, url in
                    handleShelfItemConsumed(entryIDs: ids, fileURL: url)
                }
                provider = NSItemProvider(object: firstItem)
                if pairs.count > 1 {
                    let paths = pairs.map { $0.0.path }
                    let pboardType = "NSFilenamesPboardType"
                    if let plistData = try? PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0) {
                        provider.registerDataRepresentation(forTypeIdentifier: pboardType, visibility: .all) { completion in
                            completion(plistData, nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak store] in
                                for pair in pairs {
                                    self.handleShelfItemConsumed(entryIDs: [pair.1], fileURL: pair.0)
                                }
                            }
                            return nil
                        }
                    }
                }
            }
        } else if let url = BookmarkService.resolveURL(entry.bookmarkData) {
            provider = NSItemProvider(object: url as NSURL)
        }
        let id = entry.id.uuidString
        provider.registerObject(id as NSString, visibility: .all)
        let data = id.data(using: .utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pinnerEntry.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static func entryID(fromItem item: Any?) -> UUID? {
        let str: String?
        if let s = item as? String { str = s }
        else if let d = item as? Data { str = String(data: d, encoding: .utf8) }
        else { str = nil }
        return str.flatMap(UUID.init(uuidString:))
    }

    private func loadDraggedEntryID(_ provider: NSItemProvider, completion: @escaping (UUID?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.pinnerEntry.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.pinnerEntry.identifier, options: nil) { item, _ in
                completion(Self.entryID(fromItem: item))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                completion(Self.entryID(fromItem: item))
            }
        } else {
            completion(nil)
        }
    }

    /// Drop an entry onto another one: insert above the target. Switches the
    /// tab to manual ordering first so the new arrangement sticks. Reordering
    /// is restricted to the same section (pinned / unpinned).
    private func handleEntryReorderDrop(providers: [NSItemProvider], onto target: BookmarkEntry) -> Bool {
        guard let p = providers.first else { return false }
        loadDraggedEntryID(p) { id in
            DispatchQueue.main.async {
                guard let id else { return }
                guard id != target.id else { return }
                guard let ti = tabIndex(of: target.id) else { return }
                guard let dragged = store.tabs[ti].entries.first(where: { $0.id == id }) else { return }
                guard dragged.isPinned == target.isPinned else { return }
                if sortOrder != .manual {
                    sortOrder = .manual
                    UserDefaults.standard.set(SortOrder.manual.rawValue, forKey: "CollectionBox.sortOrder")
                }
                store.reorderEntry(id, before: target.id, in: ti)
            }
        }
        return true
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var countText: some View {
        if isSearching {
            Text("\(flatDisplay.count) 个结果")
        } else if showingShelf {
            Text("\(store.shelfEntries.count) 个暂存文件 · 拖出即焚")
        } else if showingRecents {
            Text("\(store.recentEntries().count) 个最近打开")
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
            if let message = actionMessage {
                Text(message)
                    .font(.system(size: Design.caption))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message)
            } else {
                countText.font(.system(size: Design.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if showingShelf {
                if !store.shelfEntries.isEmpty {
                    Button(action: { store.clearShelf(); clearSelection() }) {
                        Text("清空暂存").font(.system(size: Design.caption)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            } else if !showingRecents {
                Button(action: { isShowingImporter = true }) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("添加文件或文件夹").accessibilityLabel("添加文件或文件夹")
                Button(action: refreshCurrentTab) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).help("刷新文件状态").accessibilityLabel("刷新文件状态")
            }
        }.padding(.horizontal, 12).padding(.vertical, 6)
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
        Haptics.success()
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
        Haptics.light()
        // `withResolvedBookmark` returns nil when the bookmark no longer
        // resolves or the target was moved / renamed / trashed. Only a real
        // open counts as success — otherwise the user gets a beep plus a
        // reason instead of a flash that implies the file opened.
        let opened = BookmarkService.withResolvedBookmark(entry.bookmarkData) { url -> Bool in
            NSWorkspace.shared.open(url)
            return true
        }
        guard opened == true else {
            NSSound.beep()
            showActionMessage("「\(entry.displayName)」已失效，无法打开")
            if let ti = tabIndex(of: entry.id) {
                Task { await store.refreshTabAsync(ti) }
            }
            return
        }
        if let ti = tabIndex(of: entry.id) {
            store.recordOpen(entry.id, in: ti); flash(entry.id)
        } else {
            flash(entry.id)
        }
    }

    /// Transient one-line message in the bottom bar, used for failures that
    /// used to be silent (missing files, refusing to open, …).
    private func showActionMessage(_ text: String) {
        actionMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if actionMessage == text { actionMessage = nil }
        }
    }

    private func moveShelfEntriesToFolder(_ entryIDs: [UUID]) {
        guard !entryIDs.isEmpty else { return }
        let entriesToMove = store.shelfEntries.filter { entryIDs.contains($0.id) }
        guard !entriesToMove.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "移动到此"
        panel.message = "选择要将暂存文件移动到的目标文件夹"

        panel.begin { response in
            guard response == .OK, let targetDirURL = panel.url else { return }

            var movedIDs: [UUID] = []
            let fm = FileManager.default

            for entry in entriesToMove {
                guard let srcURL = BookmarkService.resolveURL(entry.bookmarkData) else { continue }
                guard fm.fileExists(atPath: srcURL.path) else {
                    movedIDs.append(entry.id)
                    continue
                }

                var destURL = targetDirURL.appendingPathComponent(srcURL.lastPathComponent)
                if fm.fileExists(atPath: destURL.path) {
                    let stem = srcURL.deletingPathExtension().lastPathComponent
                    let ext = srcURL.pathExtension
                    var counter = 2
                    while fm.fileExists(atPath: destURL.path) {
                        let newName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                        destURL = targetDirURL.appendingPathComponent(newName)
                        counter += 1
                    }
                }

                do {
                    try fm.moveItem(at: srcURL, to: destURL)
                    movedIDs.append(entry.id)
                } catch {
                    NSLog("[Pinner] 移动暂存文件失败: \(srcURL.path) -> \(destURL.path), 错误: \(error.localizedDescription)")
                }
            }

            if !movedIDs.isEmpty {
                store.removeShelfEntries(movedIDs)
                pruneSelection()
            }
        }
    }

    private func saveShelfEntriesToTab(_ entryIDs: [UUID], tabIndex: Int) {
        guard !entryIDs.isEmpty, store.tabs.indices.contains(tabIndex) else { return }
        let entries = store.shelfEntries.filter { entryIDs.contains($0.id) }
        let urls = entries.compactMap { BookmarkService.resolveURL($0.bookmarkData) }
        guard !urls.isEmpty else { return }
        store.addEntries(from: urls, to: tabIndex)
        store.removeShelfEntries(entryIDs)
        pruneSelection()
    }

    private func handleShelfItemConsumed(entryIDs: [UUID], fileURL: URL) {
        let existingIDs = Set(store.shelfEntries.map(\.id))
        let idsToRemove = entryIDs.filter { existingIDs.contains($0) }
        if !idsToRemove.isEmpty {
            Haptics.levelChange()
            store.removeShelfEntries(idsToRemove)
            pruneSelection()
        }

        if shelfTrashOriginalOnDragOut, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                NSLog("[Pinner] 暂存物理剪切完成：已将源文件移至废纸篓: \(fileURL.path)")
            } catch {
                NSLog("[Pinner] 移入废纸篓失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let collectionBoxKeyDown = Notification.Name("CollectionBoxKeyDown")
    static let panelShouldCollapse = Notification.Name("PanelShouldCollapse")
    static let quickLookSelectionDidChange = Notification.Name("QuickLookSelectionDidChange")
}

// MARK: - Entry Row (List)

struct EntryRow: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false
    /// Optional source-tab label shown in cross-tab views (recents).
    var sourceLabel: String? = nil
    var onRemove: (() -> Void)? = nil
    var onReorderDrop: ([NSItemProvider]) -> Bool = { _ in false }
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(entry: entry, prefersThumbnail: false).frame(width: 20, height: 20).opacity(entry.isMissing ? 0.4 : 1)
            Text(entry.displayName).font(.system(size: Design.body)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
            if entry.isMissing {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: Design.micro)).foregroundStyle(.orange)
            }
            if let sourceLabel {
                Text(sourceLabel).font(.system(size: Design.micro)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if let onRemove, isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("从暂存架移除")
            }
        }.padding(.vertical, 3).padding(.horizontal, 6)
        .background(isFlashing ? Color.accentColor.opacity(Design.flashAlpha)
            : isSelected ? Color.accentColor.opacity(Design.selectedAlpha)
            : isHovered ? Color.secondary.opacity(Design.hoverAlpha) : Color.clear)
        .overlay(alignment: .top) {
            // Always present, toggled by opacity: adding/removing the branch
            // mid-drag invalidates the active drag session on macOS.
            Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: Design.radiusS)
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Design.radiusS))
        .onDrop(of: [.pinnerEntry, .plainText], isTargeted: $isDropTargeted) { onReorderDrop($0) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false
    var onRemove: (() -> Void)? = nil
    var onReorderDrop: ([NSItemProvider]) -> Bool = { _ in false }
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 4) {
            FileIconView(entry: entry).frame(width: 48, height: 48).frame(width: 56, height: 56)
                .background(Color.secondary.opacity(Design.wellAlpha)).cornerRadius(Design.radiusM)
                .overlay(alignment: .topTrailing) {
                    if let onRemove, isHovered {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .help("从暂存架移除")
                    } else if entry.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            .offset(x: 3, y: -3)
                    }
                }
            Text(entry.displayName).font(.system(size: Design.ui)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
                .frame(width: 76, height: 14, alignment: .top)
        }
        .frame(width: 80, height: 86)
        .background(RoundedRectangle(cornerRadius: Design.radiusM).fill(isFlashing ? Color.accentColor.opacity(Design.flashAlpha)
            : isSelected ? Color.accentColor.opacity(Design.selectedAlpha)
            : isHovered ? Color.secondary.opacity(Design.hoverAlpha) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Design.radiusM)
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
        .overlay(alignment: .top) {
            // Always present, toggled by opacity: adding/removing the branch
            // mid-drag invalidates the active drag session on macOS.
            Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .onDrop(of: [.pinnerEntry, .plainText], isTargeted: $isDropTargeted) { onReorderDrop($0) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
    }
}

// MARK: - File Icon

struct FileIconView: View {
    let entry: BookmarkEntry
    var prefersThumbnail = true
    var body: some View { FileIconWrap(entry: entry, prefersThumbnail: prefersThumbnail) }
}

#if canImport(AppKit)
struct FileIconWrap: NSViewRepresentable {
    let entry: BookmarkEntry
    /// Grid cells show a content preview; list rows keep the plain file icon.
    var prefersThumbnail = true
    static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private static let thumbnailableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "pdf"]
    /// Bookmark resolution touches the filesystem (milliseconds each), so
    /// results are cached per entry and invalidated when the bookmark data
    /// changes. Main-thread only, like every caller below.
    private static var resolvedPathCache: [UUID: (bookmark: Data, path: String?)] = [:]
    /// Paths with a thumbnail request already in flight. Without this, every
    /// re-render of a visible cell would queue another generation request.
    nonisolated(unsafe) private static var pendingThumbnails: Set<String> = []
    /// Negative cache for files whose thumbnail generation failed, avoiding infinite retry loops.
    nonisolated(unsafe) private static var failedThumbnails: Set<String> = []
    private static let pendingLock = NSLock()

    // Icons and thumbnails share NSCache but must never share a key: the icon
    // is written first, so a thumbnail lookup on the same key would hit it.
    private static func iconKey(_ path: String) -> NSString { ("icon:" + path) as NSString }
    private static func thumbnailKey(_ path: String) -> NSString { ("thumb:" + path) as NSString }

    static func cachedResolvedPath(for entry: BookmarkEntry) -> String? {
        if let hit = resolvedPathCache[entry.id], hit.bookmark == entry.bookmarkData { return hit.path }
        let path = BookmarkService.resolvedPath(entry.bookmarkData)
        resolvedPathCache[entry.id] = (entry.bookmarkData, path)
        return path
    }

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(); v.imageScaling = .scaleProportionallyUpOrDown
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        if prefersThumbnail, let path = Self.cachedResolvedPath(for: entry),
           let cached = Self.iconCache.object(forKey: Self.thumbnailKey(path)) {
            v.image = cached
            return v
        }
        v.image = Self.baseIcon(for: entry)
        if prefersThumbnail {
            Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
                if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
            }
        }
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        if prefersThumbnail, let path = Self.cachedResolvedPath(for: entry),
           let cached = Self.iconCache.object(forKey: Self.thumbnailKey(path)) {
            v.image = cached
            return
        }
        v.image = Self.baseIcon(for: entry)
        guard prefersThumbnail else { return }
        Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
            if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
        }
    }

    static func baseIcon(for entry: BookmarkEntry) -> NSImage {
        let path = cachedResolvedPath(for: entry)
        let ext = path.map { ($0 as NSString).pathExtension } ?? (entry.displayName as NSString).pathExtension
        let fallback = ext.isEmpty
            ? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
            : NSWorkspace.shared.icon(forFileType: ext)
        guard let path = path else { return fallback }
        let key = iconKey(path)
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Decodes an image/PDF/media/document thumbnail via system QLThumbnailGenerator
    /// off the main thread with fallback, and caches it under its own key.
    static func loadThumbnailIfAvailable(for entry: BookmarkEntry, completion: @escaping (NSImage) -> Void) {
        guard let path = cachedResolvedPath(for: entry) else { return }
        let pathExt = (path as NSString).pathExtension.lowercased()
        let nameExt = (entry.displayName as NSString).pathExtension.lowercased()
        let ext = !pathExt.isEmpty ? pathExt : nameExt
        guard thumbnailableExtensions.contains(ext) else { return }
        let cachedKey = thumbnailKey(path)
        if let cached = iconCache.object(forKey: cachedKey) {
            completion(cached)
            return
        }

        pendingLock.lock()
        guard !failedThumbnails.contains(path) else { pendingLock.unlock(); return }
        guard !pendingThumbnails.contains(path) else { pendingLock.unlock(); return }
        pendingThumbnails.insert(path)
        pendingLock.unlock()

        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 128, height: 128),
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            if let rep = rep {
                Self.publishThumbnail(rep.nsImage, for: path, key: cachedKey, completion: completion)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let thumb = Self.thumbnail(at: path, ext: ext, maxPixel: 256) else {
                    Self.markThumbnailFailed(path)
                    return
                }
                Self.publishThumbnail(thumb, for: path, key: cachedKey, completion: completion)
            }
        }
    }

    private static func clearPendingThumbnail(_ path: String) {
        pendingLock.lock()
        pendingThumbnails.remove(path)
        pendingLock.unlock()
    }

    private static func markThumbnailFailed(_ path: String) {
        pendingLock.lock()
        pendingThumbnails.remove(path)
        failedThumbnails.insert(path)
        pendingLock.unlock()
    }

    private static func publishThumbnail(_ image: NSImage, for path: String, key: NSString,
                                         completion: @escaping (NSImage) -> Void) {
        clearPendingThumbnail(path)
        iconCache.setObject(image, forKey: key)
        DispatchQueue.main.async { completion(image) }
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
