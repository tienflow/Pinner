import Foundation
import Observation

@Observable
public final class CollectionStore {
    public var tabs: [CollectionTab] = []
    private let persistenceKey = "CollectionBox.tabs"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public init(inMemory: Bool) {
        self.defaults = UserDefaults(suiteName: "in-memory-\(UUID().uuidString)")!
    }

    // MARK: - CRUD

    public func createTab(named name: String) {
        tabs.append(CollectionTab(id: UUID(), name: name, entries: []))
        save()
    }

    public func deleteTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        save()
    }

    public func renameTab(at index: Int, to newName: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].name = newName
        save()
    }

    // MARK: - Entry Management

    public func addEntry(_ entry: BookmarkEntry, to tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        tabs[tabIndex].entries.append(entry)
        save()
    }

    public func removeEntry(_ entryID: UUID, from tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        tabs[tabIndex].entries.removeAll { $0.id == entryID }
        save()
    }

    public func moveEntry(_ entryID: UUID, from src: Int, to dst: Int) {
        guard tabs.indices.contains(src), tabs.indices.contains(dst) else { return }
        guard let i = tabs[src].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = tabs[src].entries.remove(at: i)
        tabs[dst].entries.append(entry)
        save()
    }

    public func pinEntry(_ entryID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        tabs[tabIndex].entries[i].isPinned.toggle()
        save()
    }

    public func recordOpen(_ entryID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        tabs[tabIndex].entries[i].lastOpened = Date()
        save()
    }

    // MARK: - Refresh / Verify

    private func log(_ msg: String) {
        let line = msg + "\n"
        if let data = line.data(using: .utf8) {
            let fh = FileHandle(forWritingAtPath: "/tmp/pinner_refresh.log")
            if let fh = fh { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
            else { try? line.write(toFile: "/tmp/pinner_refresh.log", atomically: true, encoding: .utf8) }
        }
    }

    @discardableResult
    public func refreshTab(_ tabIndex: Int) -> (valid: Int, invalid: Int) {
        guard tabs.indices.contains(tabIndex) else { return (0, 0) }
        var valid = 0, invalid = 0
        var toRemove: [UUID] = []
        for entry in tabs[tabIndex].entries {
            let result = BookmarkService.refreshBookmark(entry.bookmarkData)
            if let newData = result.newData {
                if let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entry.id }) {
                    tabs[tabIndex].entries[i].bookmarkData = newData
                    if let name = result.currentName, name != entry.displayName {
                        tabs[tabIndex].entries[i].displayName = name
                    }
                }
                valid += 1
                log("[refresh] VALID: \(entry.displayName)")
            } else {
                toRemove.append(entry.id)
                invalid += 1
                log("[refresh] INVALID (will remove): \(entry.displayName)")
            }
        }
        log("[refresh] tab \(tabIndex): valid=\(valid), invalid=\(invalid), removing=\(toRemove.count)")
        if !toRemove.isEmpty {
            tabs[tabIndex].entries.removeAll { toRemove.contains($0.id) }
        }
        save()
        return (valid, invalid)
    }

    @discardableResult
    public func refreshAll() -> (valid: Int, invalid: Int) {
        var v = 0, inv = 0
        for i in tabs.indices {
            let (a, b) = refreshTab(i); v += a; inv += b
        }
        return (v, inv)
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
