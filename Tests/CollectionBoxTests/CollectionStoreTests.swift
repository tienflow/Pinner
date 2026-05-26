import Foundation
@testable import CollectionBox

// MARK: - Test Helpers

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(file):\(line)] expected \(expected), got \(actual)")
    }
}

func assertTrue(_ value: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if value {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(file):\(line)] \(message)")
    }
}

// MARK: - Tests

func testCreateTabAppendsEmptyTab() {
    let store = CollectionStore()
    store.createTab(named: "工作")
    assertEqual(store.tabs.map(\.name), ["工作"])
    assertTrue(store.tabs[0].entries.isEmpty, "entries should be empty")
}

func testDeleteTabRemovesTab() {
    let store = CollectionStore()
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.deleteTab(at: 0)
    assertEqual(store.tabs.map(\.name), ["B"])
}

func testRenameTabUpdatesName() {
    let store = CollectionStore()
    store.createTab(named: "旧名")
    store.renameTab(at: 0, to: "新名")
    assertEqual(store.tabs[0].name, "新名")
}

func testMoveEntryBetweenTabs() {
    let store = CollectionStore()
    store.createTab(named: "A")
    store.createTab(named: "B")
    let entry = BookmarkEntry(id: UUID(), displayName: "file.txt", bookmarkData: Data())
    store.tabs[0].entries = [entry]
    store.moveEntry(entry.id, from: 0, to: 1)
    assertTrue(store.tabs[0].entries.isEmpty, "source tab should be empty")
    assertEqual(store.tabs[1].entries.map(\.displayName), ["file.txt"])
}

// MARK: - Runner

print("Running CollectionStoreTests...")
testCreateTabAppendsEmptyTab()
testDeleteTabRemovesTab()
testRenameTabUpdatesName()
testMoveEntryBetweenTabs()
print("Results: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
