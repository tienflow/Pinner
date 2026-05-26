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

func testCreateMultipleTabsPreservesOrder() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.createTab(named: "C")
    assertEqual(store.tabs.map(\.name), ["A", "B", "C"])
}

func testDeleteTabRemovesTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.deleteTab(at: 0)
    assertEqual(store.tabs.map(\.name), ["B"])
}

func testDeleteAtInvalidIndexIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.deleteTab(at: -1)
    assertEqual(store.tabs.count, 1)
    store.deleteTab(at: 99)
    assertEqual(store.tabs.count, 1)
}

func testRenameTabUpdatesName() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "旧名")
    store.renameTab(at: 0, to: "新名")
    assertEqual(store.tabs[0].name, "新名")
}

func testRenameAtInvalidIndexIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.renameTab(at: 5, to: "B")
    assertEqual(store.tabs[0].name, "A")
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

func testMoveNonExistentEntryIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.moveEntry(UUID(), from: 0, to: 1)
    assertTrue(store.tabs[0].entries.isEmpty)
    assertTrue(store.tabs[1].entries.isEmpty)
}

func testMoveWithInvalidTabIndexIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    let entry = BookmarkEntry(id: UUID(), displayName: "f.txt", bookmarkData: Data())
    store.tabs[0].entries = [entry]
    store.moveEntry(entry.id, from: 0, to: 99)
    assertEqual(store.tabs[0].entries.count, 1)
}

func testAddEntryToTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "Files")
    let entry = BookmarkEntry(id: UUID(), displayName: "doc.pdf", bookmarkData: Data())
    store.addEntry(entry, to: 0)
    assertEqual(store.tabs[0].entries.count, 1)
    assertEqual(store.tabs[0].entries[0].displayName, "doc.pdf")
}

func testAddEntryToInvalidTabIndexIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    let entry = BookmarkEntry(id: UUID(), displayName: "x.txt", bookmarkData: Data())
    store.addEntry(entry, to: 99)
    assertEqual(store.tabs[0].entries.count, 0)
}

func testRemoveEntryFromTab() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "Files")
    let entry = BookmarkEntry(id: UUID(), displayName: "doc.pdf", bookmarkData: Data())
    store.addEntry(entry, to: 0)
    store.removeEntry(entry.id, from: 0)
    assertTrue(store.tabs[0].entries.isEmpty, "entries should be empty after removal")
}

func testRemoveNonExistentEntryIsNoOp() {
    let store = CollectionStore(inMemory: true)
    store.createTab(named: "A")
    let entry = BookmarkEntry(id: UUID(), displayName: "keep.txt", bookmarkData: Data())
    store.addEntry(entry, to: 0)
    store.removeEntry(UUID(), from: 0)
    assertEqual(store.tabs[0].entries.count, 1)
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

func testPersistencePreservesTabOrder() {
    let suiteName = "TestOrder-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removeSuite(named: suiteName) }

    let store1 = CollectionStore(defaults: defaults)
    store1.createTab(named: "First")
    store1.createTab(named: "Second")
    store1.createTab(named: "Third")

    let store2 = CollectionStore(defaults: defaults)
    assertEqual(store2.tabs.map(\.name), ["First", "Second", "Third"])
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

func testFreshStoreStartsEmpty() {
    let suiteName = "TestFresh-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removeSuite(named: suiteName) }

    let store = CollectionStore(defaults: defaults)
    assertTrue(store.tabs.isEmpty, "new store with no data should be empty")
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

func testBookmarkDirectory() {
    let tmpDir = FileManager.default.temporaryDirectory
    let testDir = tmpDir.appendingPathComponent("collectionbox-dir-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testDir) }

    let data = try! BookmarkService.makeBookmark(for: testDir)
    let resolved = try! BookmarkService.resolveBookmark(data)
    assertEqual(resolved.standardizedFileURL, testDir.standardizedFileURL)
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

func testResolveEmptyDataThrows() {
    do {
        _ = try BookmarkService.resolveBookmark(Data())
        failed += 1
        print("FAIL: expected error for empty bookmark data")
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
    assertEqual(decoded.originX, 100.0)
    assertEqual(decoded.originY, 200.0)
}

func testWindowStateEquatable() {
    let a = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: true)
    let b = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: true)
    let c = WindowState(originX: 0, originY: 0, width: 320, height: 480, isExpanded: false)
    assertTrue(a == b, "identical states should be equal")
    assertTrue(a != c, "different states should not be equal")
}

func testWindowStateNegativeCoordinates() {
    let state = WindowState(originX: -100, originY: -200, width: 320, height: 480, isExpanded: false)
    let data = try! JSONEncoder().encode(state)
    let decoded = try! JSONDecoder().decode(WindowState.self, from: data)
    assertEqual(decoded.originX, -100.0)
    assertEqual(decoded.isExpanded, false)
}

// MARK: - Model Tests

func testCollectionTabEquatable() {
    let id = UUID()
    let a = CollectionTab(id: id, name: "X", entries: [])
    let b = CollectionTab(id: id, name: "X", entries: [])
    let c = CollectionTab(id: id, name: "Y", entries: [])
    assertTrue(a == b, "identical tabs should be equal")
    assertTrue(a != c, "different tabs should not be equal")
}

func testBookmarkEntryEquatable() {
    let id = UUID()
    let a = BookmarkEntry(id: id, displayName: "f.txt", bookmarkData: Data([1]))
    let b = BookmarkEntry(id: id, displayName: "f.txt", bookmarkData: Data([1]))
    let c = BookmarkEntry(id: id, displayName: "f.txt", bookmarkData: Data([2]))
    assertTrue(a == b, "identical entries should be equal")
    assertTrue(a != c, "entries with different data should not be equal")
}

// MARK: - Runner

print("=== CollectionStore CRUD ===")
testCreateTabAppendsEmptyTab()
testCreateMultipleTabsPreservesOrder()
testDeleteTabRemovesTab()
testDeleteAtInvalidIndexIsNoOp()
testRenameTabUpdatesName()
testRenameAtInvalidIndexIsNoOp()
testMoveEntryBetweenTabs()
testMoveNonExistentEntryIsNoOp()
testMoveWithInvalidTabIndexIsNoOp()
testAddEntryToTab()
testAddEntryToInvalidTabIndexIsNoOp()
testRemoveEntryFromTab()
testRemoveNonExistentEntryIsNoOp()

print("=== CollectionStore Persistence ===")
testSaveAndLoad()
testPersistencePreservesTabOrder()
testClearPersistence()
testFreshStoreStartsEmpty()

print("=== BookmarkService ===")
testMakeAndResolveBookmark()
testBookmarkDirectory()
testStaleBookmarkDetection()
testResolveInvalidDataThrows()
testResolveEmptyDataThrows()

print("=== WindowState ===")
testWindowStateCodable()
testWindowStateEquatable()
testWindowStateNegativeCoordinates()

print("=== Models ===")
testCollectionTabEquatable()
testBookmarkEntryEquatable()

print("\nResults: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
