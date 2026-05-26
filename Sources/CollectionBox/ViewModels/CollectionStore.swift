import Foundation
import Observation

@Observable
final class CollectionStore {
    var tabs: [CollectionTab] = []

    private let persistenceKey = "CollectionBox.tabs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // For testing without persistence
    init(inMemory: Bool) {
        self.defaults = .standard
    }

    // MARK: - CRUD

    func createTab(named name: String) {
        tabs.append(CollectionTab(id: UUID(), name: name, entries: []))
        save()
    }

    func deleteTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        save()
    }

    func renameTab(at index: Int, to newName: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].name = newName
        save()
    }

    // MARK: - Entry Management

    func addEntry(_ entry: BookmarkEntry, to tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        tabs[tabIndex].entries.append(entry)
        save()
    }

    func removeEntry(_ entryID: UUID, from tabIndex: Int) {
        guard tabs.indices.contains(tabIndex) else { return }
        tabs[tabIndex].entries.removeAll { $0.id == entryID }
        save()
    }

    func moveEntry(_ entryID: UUID, from sourceTabIndex: Int, to destinationTabIndex: Int) {
        guard tabs.indices.contains(sourceTabIndex), tabs.indices.contains(destinationTabIndex) else { return }
        guard let entryIndex = tabs[sourceTabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = tabs[sourceTabIndex].entries.remove(at: entryIndex)
        tabs[destinationTabIndex].entries.append(entry)
        save()
    }

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(tabs) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    func load() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([CollectionTab].self, from: data) else { return }
        tabs = decoded
    }

    func clearPersistence() {
        defaults.removeObject(forKey: persistenceKey)
        tabs = []
    }
}
