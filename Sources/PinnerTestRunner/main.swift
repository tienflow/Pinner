import Foundation
import CollectionBox

// Test runner for CollectionStore / BookmarkService.
// The pure-CommandLineTools toolchain has no XCTest, so this executable
// exercises the same assertions and exits non-zero on any failure.
// Run with: swift run PinnerTestRunner

var passed = 0
var failed = 0

@MainActor
func check(_ condition: Bool, _ name: String, file: StaticString = #fileID, line: UInt = #line) {
    if condition {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        print("FAIL  \(name)  (\(file):\(line))")
    }
}

@MainActor
func makeStore() -> CollectionStore {
    CollectionStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
}

@MainActor
func makeTempFile(named name: String = "test-\(UUID().uuidString).txt") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? "pinner-test".write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
func entry(for url: URL) throws -> BookmarkEntry {
    BookmarkEntry(id: UUID(), displayName: url.lastPathComponent, bookmarkData: try BookmarkService.makeBookmark(for: url))
}

// MARK: - Suites

@MainActor
func testTabCRUD() {
    let store = makeStore()
    store.createTab(named: "工作")
    check(store.tabs.count == 1 && store.tabs[0].name == "工作", "createTab")
    store.renameTab(at: 0, to: "项目")
    check(store.tabs[0].name == "项目", "renameTab")
    store.deleteTab(at: 0)
    check(store.tabs.isEmpty, "deleteTab")
}

@MainActor
func testMoveTab() {
    let store = makeStore()
    store.createTab(named: "A")
    store.createTab(named: "B")
    store.createTab(named: "C")
    store.moveTab(from: 2, to: 0)
    check(store.tabs.map(\.name) == ["C", "A", "B"], "moveTab reorders")
    store.moveTab(from: 1, to: 1)
    check(store.tabs.map(\.name) == ["C", "A", "B"], "moveTab no-op ignored")
}

@MainActor
func testEntryOperations() throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store.addEntry(try entry(for: url), to: 0)

    check(store.tabs[0].entries.count == 1, "addEntry")
    check(!store.tabs[0].entries[0].isPinned, "new entry unpinned")
    store.pinEntry(store.tabs[0].entries[0].id, in: 0)
    check(store.tabs[0].entries[0].isPinned, "pinEntry")

    store.renameEntry(store.tabs[0].entries[0].id, in: 0, to: "新名字.txt")
    check(store.tabs[0].entries[0].displayName == "新名字.txt", "renameEntry")

    let before = store.tabs[0].entries[0].lastOpened
    store.recordOpen(store.tabs[0].entries[0].id, in: 0)
    check(store.tabs[0].entries[0].lastOpened != before, "recordOpen")

    store.removeEntry(store.tabs[0].entries[0].id, from: 0)
    check(store.tabs[0].entries.isEmpty, "removeEntry")
}

@MainActor
func testRenameEntryIgnoresEmptyName() throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store.addEntry(try entry(for: url), to: 0)
    let original = store.tabs[0].entries[0].displayName
    store.renameEntry(store.tabs[0].entries[0].id, in: 0, to: "   ")
    check(store.tabs[0].entries[0].displayName == original, "renameEntry rejects whitespace-only name")
}

@MainActor
func testAddEntriesDedup() throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    check(store.addEntries(from: [url, url, url], to: 0) == 1, "duplicate drops collapse to one entry")
    check(store.tabs[0].entries.count == 1, "tab has one entry after duplicate drops")

    let other = makeTempFile()
    defer { try? FileManager.default.removeItem(at: other) }
    check(store.addEntries(from: [other], to: 0) == 1, "different file added")
    check(store.tabs[0].entries.count == 2, "two distinct entries")

    store.createTab(named: "U")
    check(store.addEntries(from: [url], to: 1) == 1, "same file allowed in another tab")
}

@MainActor
func testRefreshMarksMissingInsteadOfRemoving() async {
    let store = makeStore()
    store.createTab(named: "T")
    store.addEntry(BookmarkEntry(id: UUID(), displayName: "ghost.txt", bookmarkData: Data([0x01, 0x02, 0x03])), to: 0)
    let id = store.tabs[0].entries[0].id

    await store.refreshTabAsync(0)
    check(store.tabs[0].entries.count == 1, "missing entry kept after refresh")
    check(store.tabs[0].entries[0].isMissing, "missing entry flagged")
    check(store.tabs[0].entries[0].id == id, "entry identity preserved")
}

@MainActor
func testRefreshClearsMissingForValidFile() async throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store.addEntry(try entry(for: url), to: 0)
    store.tabs[0].entries[0].isMissing = true

    await store.refreshTabAsync(0)
    check(!store.tabs[0].entries[0].isMissing, "valid entry clears isMissing")
}

@MainActor
func testBatchOperations() throws {
    let store = makeStore()
    store.createTab(named: "A")
    store.createTab(named: "B")
    let url1 = makeTempFile()
    let url2 = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url1) }
    defer { try? FileManager.default.removeItem(at: url2) }
    store.addEntry(try entry(for: url1), to: 0)
    store.addEntry(try entry(for: url2), to: 0)

    store.moveEntries(store.tabs[0].entries.map(\.id), to: 1)
    check(store.tabs[0].entries.isEmpty && store.tabs[1].entries.count == 2, "moveEntries batch moves")

    let id = store.tabs[1].entries[0].id
    store.removeEntriesGlobally([id])
    check(!store.tabs.flatMap { $0.entries.map(\.id) }.contains(id), "removeEntriesGlobally removes across tabs")
}

@MainActor
func testUndo() throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store.addEntry(try entry(for: url), to: 0)

    store.removeEntry(store.tabs[0].entries[0].id, from: 0)
    check(store.tabs[0].entries.isEmpty, "entry removed")
    check(store.undo(), "undo returns true")
    check(store.tabs[0].entries.count == 1, "undo restores removed entry")
    check(!store.undo(), "undo exhausted")

    store.deleteTab(at: 0)
    check(store.undo() && store.tabs.count == 1 && store.tabs[0].name == "T", "undo restores deleted tab")

    store.pinEntry(store.tabs[0].entries[0].id, in: 0)
    check(!store.undo(), "pin is not undoable")
    check(store.tabs[0].entries[0].isPinned, "pin survives undo attempt")
}

@MainActor
func testPersistenceRoundtrip() throws {
    let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let store = CollectionStore(defaults: suite)
        store.createTab(named: "持久化")
        store.addEntry(try entry(for: url), to: 0)
        store.pinEntry(store.tabs[0].entries[0].id, in: 0)
        store.tabs[0].entries[0].isMissing = true
        store.save()
    }
    let reloaded = CollectionStore(defaults: suite)
    check(reloaded.tabs.count == 1 && reloaded.tabs[0].name == "持久化", "tabs survive save/load")
    check(reloaded.tabs[0].entries.count == 1, "entries survive save/load")
    check(reloaded.tabs[0].entries[0].isPinned, "isPinned survives save/load")
    check(reloaded.tabs[0].entries[0].isMissing, "isMissing survives save/load")
}

@MainActor
func testLegacyJSONCompatibility() throws {
    let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let store0 = CollectionStore(defaults: suite)
    store0.createTab(named: "L")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store0.addEntry(try entry(for: url), to: 0)
    let data = try JSONEncoder().encode(store0.tabs)

    // Strip isMissing to simulate a payload written by an older version.
    var json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    var tab = json[0]
    var entries = tab["entries"] as! [[String: Any]]
    for i in entries.indices { entries[i]["isMissing"] = nil }
    tab["entries"] = entries
    json[0] = tab
    let legacyData = try JSONSerialization.data(withJSONObject: json)

    suite.set(legacyData, forKey: "CollectionBox.tabs")
    let reloaded = CollectionStore(defaults: suite)
    check(reloaded.tabs.count == 1 && reloaded.tabs[0].entries.count == 1, "legacy payload loads")
    check(!reloaded.tabs[0].entries[0].isMissing, "legacy payload defaults isMissing to false")
}

@MainActor
func testBookmarkServiceHelpers() throws {
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try BookmarkService.makeBookmark(for: url)
    check(BookmarkService.resolvedPath(data) == url.standardizedFileURL.path, "resolvedPath roundtrip")
    check(BookmarkService.resolvedPath(Data([0x09, 0x09])) == nil, "resolvedPath nil for garbage data")
    check(BookmarkService.resolveURL(Data([0x09, 0x09])) == nil, "resolveURL nil for garbage data")
}

// MARK: - Entry Point

let allPassed = await Task { @MainActor () -> Bool in
    testTabCRUD()
    testMoveTab()
    try? testEntryOperations()
    try? testRenameEntryIgnoresEmptyName()
    try? testAddEntriesDedup()
    await testRefreshMarksMissingInsteadOfRemoving()
    try? await testRefreshClearsMissingForValidFile()
    try? testBatchOperations()
    try? testUndo()
    try? testPersistenceRoundtrip()
    try? testLegacyJSONCompatibility()
    try? testBookmarkServiceHelpers()
    print("\n\(passed) passed, \(failed) failed")
    return failed == 0
}.value
exit(allPassed ? 0 : 1)
