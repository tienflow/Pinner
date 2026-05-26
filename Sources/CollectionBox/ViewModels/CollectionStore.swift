import Foundation
import Observation

@Observable
final class CollectionStore {
    var tabs: [CollectionTab] = []

    func createTab(named name: String) {
        tabs.append(CollectionTab(id: UUID(), name: name, entries: []))
    }

    func deleteTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
    }

    func renameTab(at index: Int, to newName: String) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].name = newName
    }

    func moveEntry(_ entryID: UUID, from sourceTabIndex: Int, to destinationTabIndex: Int) {
        guard tabs.indices.contains(sourceTabIndex), tabs.indices.contains(destinationTabIndex) else { return }
        guard let entryIndex = tabs[sourceTabIndex].entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = tabs[sourceTabIndex].entries.remove(at: entryIndex)
        tabs[destinationTabIndex].entries.append(entry)
    }
}
