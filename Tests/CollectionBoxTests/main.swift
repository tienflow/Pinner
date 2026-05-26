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

// MARK: - CollectionStore Tests

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

// MARK: - Runner

print("=== CollectionStoreTests ===")
testCreateTabAppendsEmptyTab()
testDeleteTabRemovesTab()
testRenameTabUpdatesName()
testMoveEntryBetweenTabs()

print("=== BookmarkServiceTests ===")
testMakeAndResolveBookmark()
testStaleBookmarkDetection()
testResolveInvalidDataThrows()

print("\nResults: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
