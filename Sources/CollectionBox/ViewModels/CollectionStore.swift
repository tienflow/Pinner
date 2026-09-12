import Foundation
import Observation

@MainActor
@Observable
public final class CollectionStore {
    public var tabs: [CollectionTab] = []
    private let persistenceKey = "CollectionBox.tabs"
    private let defaults: UserDefaults
    private var undoStack: [[CollectionTab]] = []
    private let maxUndoSteps = 20

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public init(inMemory: Bool) {
        self.defaults = UserDefaults(suiteName: "in-memory-\(UUID().uuidString)")!
    }

    // MARK: - Tab Management

    public func createTab(named name: String) {
        tabs.append(CollectionTab(id: UUID(), name: name, entries: []))
        save()
    }

    public func deleteTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        pushUndo()
        tabs.remove(at: index)
        save()
    }

    public func renameTab(at index: Int, to newName: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].name = newName
        save()
    }

    public func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination), source != destination else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        save()
    }

    // MARK: - Entry Management

    public func addEntry(_ entry: BookmarkEntry, to tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        tabs[tabIndex].entries.append(entry)
        save()
    }

    /// Add files to a tab, skipping entries whose resolved path already exists
    /// in that tab. Returns the number of entries actually added.
    @discardableResult
    public func addEntries(from urls: [URL], to tabIndex: Int) -> Int {
        guard tabs.indices.contains(tabIndex) else { return 0 }
        var existingPaths = Set(tabs[tabIndex].entries.compactMap { BookmarkService.resolvedPath($0.bookmarkData) })
        var added = 0
        for url in urls {
            guard let bd = try? BookmarkService.makeBookmark(for: url) else { continue }
            let path = BookmarkService.resolvedPath(bd) ?? url.standardizedFileURL.path
            guard !existingPaths.contains(path) else { continue }
            existingPaths.insert(path)
            tabs[tabIndex].entries.append(BookmarkEntry(id: UUID(), displayName: url.lastPathComponent, bookmarkData: bd))
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    public func removeEntry(_ entryID: UUID, from tabIndex: Int) {
        removeEntries([entryID], from: tabIndex)
    }

    public func removeEntries(_ entryIDs: [UUID], from tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        let idSet = Set(entryIDs)
        guard tabs[tabIndex].entries.contains(where: { idSet.contains($0.id) }) else { return }
        pushUndo()
        tabs[tabIndex].entries.removeAll { idSet.contains($0.id) }
        save()
    }

    /// Remove entries wherever they live (used for multi-tab search results).
    public func removeEntriesGlobally(_ entryIDs: [UUID]) {
        let idSet = Set(entryIDs)
        pushUndo()
        for i in tabs.indices {
            tabs[i].entries.removeAll { idSet.contains($0.id) }
        }
        save()
    }

    public func moveEntry(_ entryID: UUID, from src: Int, to dst: Int) {
        moveEntries([entryID], to: dst, fromTab: src)
    }

    /// Move entries (possibly spanning several tabs) into one destination tab.
    public func moveEntries(_ entryIDs: [UUID], to dst: Int, fromTab src: Int? = nil) {
        guard tabs.indices.contains(dst) else { return }
        let idSet = Set(entryIDs)
        let moving = tabs.enumerated().flatMap { i, tab in
            tab.entries.filter { idSet.contains($0.id) && (src == nil || src == i) }
        }
        guard !moving.isEmpty else { return }
        pushUndo()
        for i in tabs.indices {
            tabs[i].entries.removeAll { idSet.contains($0.id) }
        }
        tabs[dst].entries.append(contentsOf: moving)
        save()
    }

    /// Move an entry to sit directly before another one within the same tab.
    /// The array order is the manual ("自定义") sort order.
    public func reorderEntry(_ entryID: UUID, before targetID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex), entryID != targetID else { return }
        guard let from = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = tabs[tabIndex].entries.remove(at: from)
        if let to = tabs[tabIndex].entries.firstIndex(where: { $0.id == targetID }) {
            tabs[tabIndex].entries.insert(entry, at: to)
        } else {
            tabs[tabIndex].entries.insert(entry, at: from)
        }
        save()
    }

    public func pinEntry(_ entryID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        tabs[tabIndex].entries[i].isPinned.toggle()
        save()
    }

    public func renameEntry(_ entryID: UUID, in tabIndex: Int, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard tabs.indices.contains(tabIndex),
              let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }),
              !trimmed.isEmpty else { return }
        tabs[tabIndex].entries[i].displayName = trimmed
        save()
    }

    public func recordOpen(_ entryID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        tabs[tabIndex].entries[i].lastOpened = Date()
        save()
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(tabs)
        if undoStack.count > maxUndoSteps { undoStack.removeFirst() }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        tabs = previous
        save()
        return true
    }

    // MARK: - Refresh / Verify
    //
    // Invalid entries are kept and flagged `isMissing` instead of being
    // removed: a bookmark can fail to resolve while its volume is merely
    // unmounted or asleep, and silently deleting the favorite would be
    // irreversible data loss.

    private struct RefreshResult: Sendable {
        let tabID: UUID
        let updates: [EntryUpdate]
    }

    private struct EntryUpdate: Sendable {
        let entryID: UUID
        let newData: Data?
        let currentName: String?
    }

    /// Refresh every tab. Resolution runs off the main thread; mutations are
    /// applied back on the main actor.
    public func refreshAllAsync() async {
        let snapshot: [(tabID: UUID, entries: [(id: UUID, data: Data)])] =
            tabs.map { ($0.id, $0.entries.map { ($0.id, $0.bookmarkData) }) }

        let computed: [RefreshResult] = await Task.detached(priority: .userInitiated) {
            snapshot.map { tab in
                RefreshResult(
                    tabID: tab.tabID,
                    updates: tab.entries.map { entry in
                        let r = BookmarkService.refreshBookmark(entry.data)
                        return EntryUpdate(entryID: entry.id, newData: r.newData, currentName: r.currentName)
                    }
                )
            }
        }.value

        apply(computed)
    }

    /// Refresh a single tab.
    public func refreshTabAsync(_ tabIndex: Int) async {
        guard tabs.indices.contains(tabIndex) else { return }
        let tabID = tabs[tabIndex].id
        let snapshot = tabs[tabIndex].entries.map { (id: $0.id, data: $0.bookmarkData) }

        let computed: RefreshResult = await Task.detached(priority: .userInitiated) {
            RefreshResult(
                tabID: tabID,
                updates: snapshot.map { entry in
                    let r = BookmarkService.refreshBookmark(entry.data)
                    return EntryUpdate(entryID: entry.id, newData: r.newData, currentName: r.currentName)
                }
            )
        }.value

        apply([computed])
    }

    private func apply(_ results: [RefreshResult]) {
        var changed = false
        for result in results {
            guard let ti = tabs.firstIndex(where: { $0.id == result.tabID }) else { continue }
            for update in result.updates {
                guard let i = tabs[ti].entries.firstIndex(where: { $0.id == update.entryID }) else { continue }
                let missing = update.newData == nil
                if tabs[ti].entries[i].isMissing != missing { tabs[ti].entries[i].isMissing = missing; changed = true }
                if let newData = update.newData, tabs[ti].entries[i].bookmarkData != newData {
                    tabs[ti].entries[i].bookmarkData = newData; changed = true
                }
                if let name = update.currentName, name != tabs[ti].entries[i].displayName {
                    tabs[ti].entries[i].displayName = name; changed = true
                }
            }
        }
        if changed { save() }
    }

    // MARK: - Persistence

    public func save() {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    public func load() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([CollectionTab].self, from: data) else { return }
        tabs = decoded
    }

    public func clearPersistence() {
        defaults.removeObject(forKey: persistenceKey)
        tabs = []
    }
}
