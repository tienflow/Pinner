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

// MARK: - CollectionStore CRUD Tests

func testCreateTabAppendsEmptyTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "工作")
    assertEqual(store.tabs.map(\.name), ["工作"])
    assertTrue(store.tabs[0].entries.isEmpty, "entries should be empty")
}

func testDeleteTabRemovesTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.deleteTab(at: 0)
    assertEqual(store.tabs.map(\.name), ["B"])
}

func testRenameTabUpdatesName() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "旧名")
    store.renameTab(at: 0, to: "新名")
    assertEqual(store.tabs[0].name, "新名")
}

func testMoveEntryBetweenTabs() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.createTab(named: "B")
    let entry = BookmarkEntry(id: UUID(), displayName: "file.txt", bookmarkData: Data())
    store.tabs[0].entries = [entry]
    store.moveEntry(entry.id, from: 0, to: 1)
    assertTrue(store.tabs[0].entries.isEmpty, "source tab should be empty")
    assertEqual(store.tabs[1].entries.map(\.displayName), ["file.txt"])
}

func testAddEntryToTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "Files")
    let entry = BookmarkEntry(id: UUID(), displayName: "doc.pdf", bookmarkData: Data())
    store.addEntry(entry, to: 0)
    assertEqual(store.tabs[0].entries.count, 1)
    assertEqual(store.tabs[0].entries[0].displayName, "doc.pdf")
}

func testRemoveEntryFromTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "Files")
    let entry = BookmarkEntry(id: UUID(), displayName: "doc.pdf", bookmarkData: Data())
    store.addEntry(entry, to: 0)
    store.removeEntry(entry.id, from: 0)
    assertTrue(store.tabs[0].entries.isEmpty, "entries should be empty after removal")
}

// MARK: - CollectionStore Persistence Tests

func testSaveAndLoad() {
    let suiteName = "TestSaveLoad-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removeSuite(named: suiteName) }

    let store1 = CollectionStore(defaults: defaults)
    store1.createTab(named: "Tab1")
    store1.createTab(named: "Tab2")
    let entry = BookmarkEntry(id: UUID(), displayName: "test.txt", bookmarkData: Data([1, 2, 3]))
    store1.addEntry(entry, to: 0)

    let store2 = CollectionStore(defaults: defaults)
    assertEqual(store2.tabs.count, 2)
    assertEqual(store2.tabs[0].name, "Tab1")
    assertEqual(store2.tabs[1].name, "Tab2")
    assertEqual(store2.tabs[0].entries.count, 1)
    assertEqual(store2.tabs[0].entries[0].displayName, "test.txt")
    assertEqual(store2.tabs[0].entries[0].bookmarkData, Data([1, 2, 3]))
}

func testClearPersistence() {
    let suiteName = "TestClear-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removeSuite(named: suiteName) }

    let store = CollectionStore(defaults: defaults)
    store.createTab(named: "ephemeral")
    store.clearPersistence()
    assertTrue(store.tabs.isEmpty, "tabs should be empty after clear")

    let store2 = CollectionStore(defaults: defaults)
    assertTrue(store2.tabs.isEmpty, "fresh store should also be empty")
}

// MARK: - BookmarkService Tests

func testMakeAndResolveBookmark() {
    let tmpDir = FileManager.default.temporaryDirectory
    let testFile = tmpDir.appendingPathComponent("collectionbox-test-\(UUID().uuidString).txt")
    try! "hello".write(to: testFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: testFile) }

    let data = try! BookmarkService.makeBookmark(for: testFile)
    let resolved = try! BookmarkService.resolveBookmark(data)
    assertEqual(resolved.standardizedFileURL, testFile.standardizedFileURL)
}

func testStaleBookmarkDetection() {
    let tmpDir = FileManager.default.temporaryDirectory
    let testFile = tmpDir.appendingPathComponent("collectionbox-stale-\(UUID().uuidString).txt")
    try! "stale".write(to: testFile, atomically: true, encoding: .utf8)

    let data = try! BookmarkService.makeBookmark(for: testFile)
    try! FileManager.default.removeItem(at: testFile)

    do {
        _ = try BookmarkService.resolveBookmark(data)
        passed += 1
    } catch {
        passed += 1
    }
}

func testResolveInvalidDataThrows() {
    let garbage = Data("not a bookmark".utf8)
    do {
        _ = try BookmarkService.resolveBookmark(garbage)
        failed += 1
        print("FAIL: expected error for invalid bookmark data")
    } catch {
        passed += 1
    }
}

// MARK: - WindowState Tests

func testWindowStateCodable() {
    let state = WindowState(originX: 100, originY: 200, width: 320, height: 480, isExpanded: true)
    let data = try! JSONEncoder().encode(state)
    let decoded = try! JSONDecoder().decode(WindowState.self, from: data)
    assertEqual(decoded.isExpanded, true)
    assertEqual(decoded.width, 320.0)
    assertEqual(decoded.height, 480.0)
}

func testWindowStateEquatable() {
    let a = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: true)
    let b = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: true)
    let c = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: false)
    assertTrue(a == b, "identical states should be equal")
    assertTrue(a != c, "different states should not be equal")
}

// MARK: - Runner

print("=== CollectionStore CRUD ===")
testCreateTabAppendsEmptyTab()
testDeleteTabRemovesTab()
testRenameTabUpdatesName()
testMoveEntryBetweenTabs()
testAddEntryToTab()
testRemoveEntryFromTab()

print("=== CollectionStore Persistence ===")
testSaveAndLoad()
testClearPersistence()

print("=== BookmarkService ===")
testMakeAndResolveBookmark()
testStaleBookmarkDetection()
testResolveInvalidDataThrows()

print("=== WindowState ===")
testWindowStateCodable()
testWindowStateEquatable()

print("\nResults: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
