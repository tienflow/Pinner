import Foundation
import AppKit
import CollectionBox
@testable import CollectionBox

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
func testRecentEntries() throws {
    let store = makeStore()
    store.createTab(named: "A")
    store.createTab(named: "B")
    let u1 = makeTempFile(named: "recent-a.txt")
    let u2 = makeTempFile(named: "recent-b.txt")
    let u3 = makeTempFile(named: "recent-c.txt")
    defer {
        try? FileManager.default.removeItem(at: u1)
        try? FileManager.default.removeItem(at: u2)
        try? FileManager.default.removeItem(at: u3)
    }
    let e1 = try entry(for: u1)
    let e2 = try entry(for: u2)
    let e3 = try entry(for: u3)
    store.addEntry(e1, to: 0)
    store.addEntry(e2, to: 1)
    store.addEntry(e3, to: 1)

    // 从未打开过的条目不进入"最近"
    check(store.recentEntries().isEmpty, "recentEntries empty before any open")

    // 显式设置打开时间（避免 Date() 精度导致的顺序不稳定）
    store.tabs[0].entries[0].lastOpened = Date(timeIntervalSinceNow: -100)
    store.tabs[1].entries[0].lastOpened = Date(timeIntervalSinceNow: -10)
    store.tabs[1].entries[1].lastOpened = Date(timeIntervalSinceNow: -50)

    let recents = store.recentEntries()
    check(recents.count == 3, "recentEntries returns all opened entries")
    check(recents[0].entry.id == e2.id, "recentEntries newest first")
    check(recents[0].tabIndex == 1, "recentEntries carries source tab index")
    check(recents[2].entry.id == e1.id, "recentEntries oldest last")
    check(recents[2].tabIndex == 0, "recentEntries oldest source tab")

    let limited = store.recentEntries(limit: 2)
    check(limited.count == 2 && limited[0].entry.id == e2.id, "recentEntries respects limit")
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
func testReorderEntry() throws {
    let suite = UserDefaults(suiteName: "test-reorder-\(UUID().uuidString)")!
    let store = CollectionStore(defaults: suite)
    store.createTab(named: "T")
    let urls = (1...3).map { makeTempFile(named: "reorder-\($0).txt") }
    defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    try store.addEntries(from: urls, to: 0)
    let ids = store.tabs[0].entries.map(\.id)

    store.reorderEntry(ids[2], before: ids[0], in: 0)
    check(store.tabs[0].entries.map(\.id) == [ids[2], ids[0], ids[1]], "reorderEntry inserts before target")

    // Array order must survive save/load — it IS the manual order.
    let reloaded = CollectionStore(defaults: suite)
    check(reloaded.tabs[0].entries.map(\.id) == [ids[2], ids[0], ids[1]], "manual order survives save/load")

    store.reorderEntry(ids[0], before: ids[0], in: 0)
    check(store.tabs[0].entries.map(\.id) == [ids[2], ids[0], ids[1]], "self-reorder ignored")
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

@MainActor
func testAgentSelectionPersistence() {
    let suite = UserDefaults(suiteName: "test-agent-selection-\(UUID().uuidString)")!
    let selection = StatsAgentSelection(defaults: suite)
    check(selection.enabledAgents == Set(StatsAgent.allCases), "agent selection defaults to all")

    selection.setEnabled(.codex, to: false)
    selection.setEnabled(.zcode, to: false)
    check(!selection.enabledAgents.contains(.codex), "agent selection toggle off persists in set")
    let reloaded = StatsAgentSelection(defaults: suite)
    check(reloaded.enabledAgents == selection.enabledAgents, "agent selection survives reload")

    let minimal = StatsAgentSelection(defaults: suite)
    for agent in StatsAgent.allCases.dropFirst() { minimal.setEnabled(agent, to: false) }
    let last = StatsAgent.allCases.last!
    check(minimal.enabledAgents == [last], "agent selection keeps the last agent on")
    minimal.setEnabled(last, to: false)
    check(minimal.enabledAgents == [last], "agent selection refuses to disable the last agent")
}

@MainActor
func testMenuBarMenuFollowsSelection() {
    let all: Set<StatsAgent> = [.codex, .gemini, .workbuddy, .zcode, .dsh]
    let titles = MenuBarController(store: CollectionStore(inMemory: true)).makeMenu(enabledAgents: all).items.map { $0.title }
    for agent in StatsAgent.allCases {
        check(titles.contains("\(agent.label) 统计"), "menu shows \(agent.label) stats when enabled")
    }

    let titlesWithOnlyCodex = MenuBarController(store: CollectionStore(inMemory: true)).makeMenu(enabledAgents: [.codex]).items.map { $0.title }
    check(titlesWithOnlyCodex.contains("Codex 统计"), "menu shows Codex stats when only Codex enabled")
    check(!titlesWithOnlyCodex.contains("Antigravity 统计"), "menu hides Antigravity stats when disabled")
    check(!titlesWithOnlyCodex.contains("Antigravity 统计快捷键"), "menu hides Antigravity hotkey when disabled")
    check(!titlesWithOnlyCodex.contains("WorkBuddy 统计"), "menu hides WorkBuddy stats when disabled")
    check(!titlesWithOnlyCodex.contains("ZCode 统计"), "menu hides ZCode stats when disabled")
    check(!titlesWithOnlyCodex.contains("DSH 统计"), "menu hides DSH stats when disabled")
    check(titlesWithOnlyCodex.contains("总览"), "menu keeps the dashboard entry")
    check(titlesWithOnlyCodex.contains("设置"), "menu keeps settings entry")
    check(titlesWithOnlyCodex.contains("退出"), "menu keeps quit entry")
}

@MainActor
func testSettingsSubmenuContents() {
    let controller = MenuBarController(store: CollectionStore(inMemory: true))
    let settings = controller.makeMenu(enabledAgents: Set(StatsAgent.allCases)).items.first { $0.title == "设置" }
    check(settings != nil, "settings submenu exists")
    guard let submenu = settings?.submenu else { return }
    let settingTitles = submenu.items.map { $0.title }
    check(settingTitles.contains("总览快捷键"), "settings has dashboard hotkey")
    for agent in StatsAgent.allCases {
        check(settingTitles.contains("\(agent.label) 统计快捷键"), "settings has \(agent.label) hotkey")
    }
    check(settingTitles.contains("主题"), "settings has theme entry")
    check(settingTitles.contains("登录时启动"), "settings has launch-at-login entry")

    // Top-level menu must not expose hotkey config anymore.
    let topTitles = controller.makeMenu(enabledAgents: Set(StatsAgent.allCases)).items.map { $0.title }
    check(!topTitles.contains { $0.hasSuffix("快捷键") }, "top-level menu hides hotkey items")

    // The "总览" item must actually be wired to an action, not a stub.
    let header = controller.makeMenu(enabledAgents: Set(StatsAgent.allCases)).items.first { $0.title == "总览" }
    check(header?.action != nil && header?.target != nil, "dashboard menu item is wired to an action")

    // Fire the action for real: the dashboard window must appear. The runner
    // has no app lifecycle, so NSApplication must be created first.
    _ = NSApplication.shared
    if let header, let action = header.action, NSApp.sendAction(action, to: header.target, from: header) {
        let found = NSApp.windows.contains { $0.title == "总览" }
        check(found, "dashboard action opens the overview window")
        if found { NSApp.windows.first { $0.title == "总览" }?.close() }
    }
}

@MainActor
func testDshScanCacheReusesResults() async {
    // Real path: StatsDashboardService.collect(.dsh) twice. The DSH service
    // holds a 120s scan cache, so the second full-range call must return the
    // same record count from cache — and fast.
    let service = StatsDashboardService()
    let t0 = Date()
    let first = service.collect(agent: .dsh, sinceMs: 0)
    let cold = Date().timeIntervalSince(t0)

    let t1 = Date()
    let second = service.collect(agent: .dsh, sinceMs: 0)
    let warm = Date().timeIntervalSince(t1)

    check(first.count == second.count && !second.isEmpty, "dsh cached collect returns same records (\(first.count))")
    check(warm < max(0.05, cold * 0.2), "dsh cached collect is fast (cold \(String(format: "%.3f", cold))s, warm \(String(format: "%.3f", warm))s)")
}

@MainActor
func testAgentSymbolsExist() {
    for agent in StatsAgent.allCases {
        check(NSImage(systemSymbolName: agent.symbolName, accessibilityDescription: nil) != nil,
              "symbol exists: \(agent.rawValue) -> \(agent.symbolName)")
    }
}

@MainActor
func testDailySortHelpers() {
    // Real comparator behavior over synthetic rows (internal via @testable).
    let a = StatsDashboardView.DayRow(id: "1", date: "2026-09-17", total: 100, fresh: 10, cached: 20, output: 30, sessions: 2)
    let b = StatsDashboardView.DayRow(id: "2", date: "2026-09-18", total: 300, fresh: 40, cached: 50, output: 60, sessions: 5)
    let view = StatsDashboardView()

    let dateDesc = view.dailySort(key: "date", ascending: false)
    check(!dateDesc(a, b) && dateDesc(b, a), "daily date sort desc puts newer first")
    let totalAsc = view.dailySort(key: "total", ascending: true)
    check(totalAsc(a, b) && !totalAsc(b, a), "daily total sort asc orders by tokens")

    let s1 = StatsDashboardView.SessionRow(id: "s1", title: "a 会话", agent: .codex, tokens: 500, turns: 3)
    let s2 = StatsDashboardView.SessionRow(id: "s2", title: "b 会话", agent: .dsh, tokens: 900, turns: 1)
    let tokensDesc = view.sessionSort(key: "tokens", ascending: false)
    check(tokensDesc(s2, s1), "session tokens desc puts bigger first")
    let turnsAsc = view.sessionSort(key: "turns", ascending: true)
    check(turnsAsc(s2, s1) && !turnsAsc(s1, s2), "session turns asc orders by turns")

    let m1 = StatsDashboardView.ModelRankRow(id: "x", name: "model-a", agents: "Codex", tokens: 700, sessions: 4)
    let m2 = StatsDashboardView.ModelRankRow(id: "y", name: "model-b", agents: "DSH", tokens: 200, sessions: 9)
    let modelDesc = view.modelSort(key: "tokens", ascending: false)
    check(modelDesc(m1, m2) && !modelDesc(m2, m1), "model tokens desc orders by tokens")
    let modelSessions = view.modelSort(key: "sessions", ascending: true)
    check(modelSessions(m1, m2), "model sessions asc orders by sessions")
}

@MainActor
func testHotkeyFailureDetection() {
    // Real Carbon duplicate-combo path: two managers, same combo. The second
    // RegisterEventHotKey must fail and be reported.
    _ = NSApplication.shared
    let prefix = "CollectionBox.testDupHotkey"
    let combo = HotkeyCombo(keyCode: 111, modifiers: 13)  // F4-ish, unlikely used
    let first = AgentStatsHotkeyManager(keyPrefix: prefix + "A", eventID: 61)
    let second = AgentStatsHotkeyManager(keyPrefix: prefix + "B", eventID: 62)
    first.save(combo: combo)
    check(first.lastRegistrationSucceeded == true, "first registration of a free combo succeeds")
    second.save(combo: combo)
    check(second.lastRegistrationSucceeded == false, "duplicate combo registration is detected as failure")
    second.clear()
    check(second.lastRegistrationSucceeded == nil, "clear resets registration state")
    first.clear()
}

@MainActor
func testAgentStatsHotkeyManagerLifecycle() {
    let prefix = "CollectionBox.dashboardHotkey"
    let manager = AgentStatsHotkeyManager(keyPrefix: prefix, eventID: 8)
    // Optional binding: nothing registered by default.
    check(UserDefaults.standard.object(forKey: prefix + "Code") == nil, "dashboard hotkey unset by default")

    manager.save(combo: HotkeyCombo(keyCode: 16, modifiers: 13))
    check(UserDefaults.standard.integer(forKey: prefix + "Code") == 16, "dashboard hotkey save persists code")
    check(UserDefaults.standard.integer(forKey: prefix + "Mods") > 0, "dashboard hotkey save persists mods")
    check(manager.currentCombo != nil, "dashboard hotkey currentCombo after save")

    manager.clear()
    check(UserDefaults.standard.object(forKey: prefix + "Code") == nil, "dashboard hotkey clear removes binding")
    check(manager.currentCombo == nil, "dashboard hotkey cleared")
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
    try? testReorderEntry()
    try? testUndo()
    try? testRecentEntries()
    try? testPersistenceRoundtrip()
    try? testLegacyJSONCompatibility()
    try? testBookmarkServiceHelpers()
    testAgentSelectionPersistence()
    testMenuBarMenuFollowsSelection()
    testSettingsSubmenuContents()
    testAgentStatsHotkeyManagerLifecycle()
    testAgentSymbolsExist()
    await testDshScanCacheReusesResults()
    testDailySortHelpers()
    print("\n\(passed) passed, \(failed) failed")
    return failed == 0
}.value
exit(allPassed ? 0 : 1)
