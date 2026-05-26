import SwiftUI

struct RootView: View {
    @State var store: CollectionStore
    @State private var selectedTabID: UUID?
    @State private var newTabName: String = ""

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
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(store.tabs) { tab in
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
            Spacer()
            addTabButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var addTabButton: some View {
        Menu {
            Button("新建 Tab") {
                store.createTab(named: "新 Tab")
                selectedTabID = store.tabs.last?.id
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Entry List

    private var entryList: some View {
        Group {
            if let tabID = selectedTabID,
               let tabIndex = store.tabs.firstIndex(where: { $0.id == tabID }) {
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
            } else {
                VStack {
                    Spacer()
                    Text("选择一个 Tab 或创建新 Tab")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
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
