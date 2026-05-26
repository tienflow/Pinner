import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @State var store: CollectionStore
    @State private var selectedTabID: UUID?
    @State private var isShowingNewTabAlert = false
    @State private var newTabName = ""
    @State private var renamingTabID: UUID?
    @State private var renameText = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            entryList
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
            Button("取消", role: .cancel) {
                newTabName = ""
            }
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
                    if !name.isEmpty {
                        store.renameTab(at: index, to: name)
                    }
                }
                renamingTabID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("取消", role: .cancel) {
                renamingTabID = nil
            }
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

    // MARK: - Entry List

    private var entryList: some View {
        Group {
            if let tabID = selectedTabID,
               let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) {
                if store.tabs[tabIndex].entries.isEmpty {
                    emptyState
                        .overlay(dropOverlay)
                        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                            handleDrop(providers: providers, tabIndex: tabIndex)
                        }
                } else {
                    List {
                        ForEach(store.tabs[tabIndex].entries) { entry in
                            EntryRow(entry: entry) {
                                openEntry(entry)
                            } onRemove: {
                                store.removeEntry(entry.id, from: tabIndex)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .overlay(dropOverlay)
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
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
    }

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

    private var dropOverlay: some View {
        Group {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
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

    private func openEntry(_ entry: BookmarkEntry) {
        guard let url = try? BookmarkService.resolveBookmark(entry.bookmarkData) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Entry Row

struct EntryRow: View {
    let entry: BookmarkEntry
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(entry.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(0.5)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onTap)
    }

    private var icon: String {
        entry.displayName.contains(".") ? "doc" : "folder"
    }
}
