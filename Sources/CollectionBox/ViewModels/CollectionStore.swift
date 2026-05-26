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
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }), i > 0 else { return }
        let entry = tabs[tabIndex].entries.remove(at: i)
        tabs[tabIndex].entries.insert(entry, at: 0)
        save()
    }

    public func recordOpen(_ entryID: UUID, in tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        guard let i = tabs[tabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        tabs[tabIndex].entries[i].lastOpened = Date()
        save()
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
