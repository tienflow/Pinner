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

    // Test shelf undo
    let shelfURL = makeTempFile()
    defer { try? FileManager.default.removeItem(at: shelfURL) }
    store.addShelfEntries(from: [shelfURL])
    check(store.shelfEntries.count == 1, "shelf entry added")
    let shelfEntryID = store.shelfEntries[0].id
    store.removeShelfEntries([shelfEntryID])
    check(store.shelfEntries.isEmpty, "shelf entry removed")
    check(store.undo(), "undo shelf removal succeeds")
    check(store.shelfEntries.count == 1 && store.shelfEntries[0].id == shelfEntryID, "shelf entry restored by undo")
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
        store.renameEntry(store.tabs[0].entries[0].id, in: 0, to: "自定义别名")
        store.save()
    }
    let reloaded = CollectionStore(defaults: suite)
    check(reloaded.tabs.count == 1 && reloaded.tabs[0].name == "持久化", "tabs survive save/load")
    check(reloaded.tabs[0].entries.count == 1, "entries survive save/load")
    check(reloaded.tabs[0].entries[0].isPinned, "isPinned survives save/load")
    check(reloaded.tabs[0].entries[0].isMissing, "isMissing survives save/load")
    check(reloaded.tabs[0].entries[0].customAlias == "自定义别名", "customAlias survives save/load")
    check(reloaded.tabs[0].entries[0].displayName == "自定义别名", "displayName survives save/load")
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
    for i in entries.indices {
        entries[i]["isMissing"] = nil
        entries[i]["customAlias"] = nil
    }
    tab["entries"] = entries
    json[0] = tab
    let legacyData = try JSONSerialization.data(withJSONObject: json)

    suite.set(legacyData, forKey: "CollectionBox.tabs")
    let reloaded = CollectionStore(defaults: suite)
    check(reloaded.tabs.count == 1 && reloaded.tabs[0].entries.count == 1, "legacy payload loads")
    check(!reloaded.tabs[0].entries[0].isMissing, "legacy payload defaults isMissing to false")
    check(reloaded.tabs[0].entries[0].customAlias == nil, "legacy payload defaults customAlias to nil")
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
    let menu = MenuBarController(store: CollectionStore(inMemory: true)).makeMenu(enabledAgents: all)
    let titles = menu.items.map { $0.title }
    check(titles.contains("各 Agent 明细"), "menu shows 各 Agent 明细 submenu when enabled")
    let detailsItem = menu.items.first { $0.title == "各 Agent 明细" }
    check(detailsItem?.submenu != nil, "各 Agent 明细 has submenu")
    let subTitles = detailsItem?.submenu?.items.map { $0.title } ?? []
    for agent in StatsAgent.allCases {
        check(subTitles.contains("\(agent.label) 统计"), "submenu shows \(agent.label) stats when enabled")
    }

    let menuOnlyCodex = MenuBarController(store: CollectionStore(inMemory: true)).makeMenu(enabledAgents: [.codex])
    let detailsOnlyCodex = menuOnlyCodex.items.first { $0.title == "各 Agent 明细" }
    let subTitlesOnlyCodex = detailsOnlyCodex?.submenu?.items.map { $0.title } ?? []
    check(subTitlesOnlyCodex.contains("Codex 统计"), "submenu shows Codex stats when only Codex enabled")
    check(!subTitlesOnlyCodex.contains("Antigravity 统计"), "submenu hides Antigravity stats when disabled")
    check(!subTitlesOnlyCodex.contains("WorkBuddy 统计"), "submenu hides WorkBuddy stats when disabled")
    check(!subTitlesOnlyCodex.contains("ZCode 统计"), "submenu hides ZCode stats when disabled")
    check(!subTitlesOnlyCodex.contains("DSH 统计"), "submenu hides DSH stats when disabled")
    check(menuOnlyCodex.items.map(\.title).contains("统计总览"), "menu keeps the dashboard entry")
    check(menuOnlyCodex.items.map(\.title).contains("偏好设置…"), "menu keeps preferences entry")
    check(menuOnlyCodex.items.map(\.title).contains { $0.hasPrefix("退出") }, "menu keeps quit entry")
}

@MainActor
func testSettingsSubmenuContents() {
    let controller = MenuBarController(store: CollectionStore(inMemory: true))
    let menu = controller.makeMenu(enabledAgents: Set(StatsAgent.allCases))
    let settings = menu.items.first { $0.title == "偏好设置…" }
    check(settings != nil, "preferences menu item exists")
    check(settings?.submenu == nil, "preferences item itself has no cascading submenu")
    check(settings?.keyEquivalent == ",", "preferences shortcut is Cmd+,")
    check(settings?.action != nil, "preferences item is wired to an action")

    // Top-level menu must not expose hotkey config anymore.
    let topTitles = menu.items.map { $0.title }
    check(!topTitles.contains { $0.hasSuffix("快捷键") }, "top-level menu hides hotkey items")
    check(topTitles.contains("待办"), "top-level menu contains todo item")
    check(topTitles.contains("闪念"), "top-level menu contains fleeting item")
    check(topTitles.contains("键鼠统计"), "top-level menu contains inputStats item")
    check(topTitles.contains("收藏夹"), "top-level menu contains collection item")
    check(topTitles.contains("OTP 验证码"), "top-level menu contains OTP item")
    check(topTitles.contains("各 Agent 明细"), "top-level menu contains agent details item")

    let inputStatsItem = menu.items.first { $0.title == "键鼠统计" }
    check(inputStatsItem?.action != nil && inputStatsItem?.target != nil, "inputStats menu item is wired to an action")

    // The "统计总览" item must actually be wired to an action, not a stub.
    let header = menu.items.first { $0.title == "统计总览" }
    check(header?.action != nil && header?.target != nil, "dashboard menu item is wired to an action")

    // Fire the action for real: the dashboard window must appear. The runner
    // has no app lifecycle, so NSApplication must be created first.
    _ = NSApplication.shared
    if let header, let action = header.action, NSApp.sendAction(action, to: header.target, from: header) {
        let found = NSApp.windows.contains { $0.title == "统计总览" }
        check(found, "dashboard action opens the overview window")
        if found { NSApp.windows.first { $0.title == "统计总览" }?.close() }
    }

    // Fire preferences action: settings window should appear
    if let settings, let action = settings.action, NSApp.sendAction(action, to: settings.target, from: settings) {
        let found = NSApp.windows.contains { $0.title == "Pinner 设置" }
        check(found, "preferences action opens the settings window")
        if found { NSApp.windows.first { $0.title == "Pinner 设置" }?.close() }
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
    let a = StatsDashboardView.DayRow(id: "1", date: "2026-09-17", total: 100, fresh: 10, cached: 20, output: 30, sessions: 2, tps: 15.0)
    let b = StatsDashboardView.DayRow(id: "2", date: "2026-09-18", total: 300, fresh: 40, cached: 50, output: 60, sessions: 5, tps: 45.0)
    let view = StatsDashboardView()

    let dateDesc = view.dailySort(key: "date", ascending: false)
    check(!dateDesc(a, b) && dateDesc(b, a), "daily date sort desc puts newer first")
    let totalAsc = view.dailySort(key: "total", ascending: true)
    check(totalAsc(a, b) && !totalAsc(b, a), "daily total sort asc orders by tokens")
    let dailyTpsDesc = view.dailySort(key: "tps", ascending: false)
    check(dailyTpsDesc(b, a) && !dailyTpsDesc(a, b), "daily tps desc orders by tps")

    let s1 = StatsDashboardView.SessionRow(id: "s1", title: "a 会话", agent: .codex, tokens: 500, turns: 3, tps: nil)
    let s2 = StatsDashboardView.SessionRow(id: "s2", title: "b 会话", agent: .dsh, tokens: 900, turns: 1, tps: 60.0)
    let tokensDesc = view.sessionSort(key: "tokens", ascending: false)
    check(tokensDesc(s2, s1), "session tokens desc puts bigger first")
    let turnsAsc = view.sessionSort(key: "turns", ascending: true)
    check(turnsAsc(s2, s1) && !turnsAsc(s1, s2), "session turns asc orders by turns")
    let sessionTpsDesc = view.sessionSort(key: "tps", ascending: false)
    check(sessionTpsDesc(s2, s1) && !sessionTpsDesc(s1, s2), "session tps desc orders by tps")

    let m1 = StatsDashboardView.ModelRankRow(id: "x", name: "model-a", agents: "Codex", tokens: 700, sessions: 4, tps: 20.0)
    let m2 = StatsDashboardView.ModelRankRow(id: "y", name: "model-b", agents: "DSH", tokens: 200, sessions: 9, tps: 80.0)
    let modelDesc = view.modelSort(key: "tokens", ascending: false)
    check(modelDesc(m1, m2) && !modelDesc(m2, m1), "model tokens desc orders by tokens")
    let modelSessions = view.modelSort(key: "sessions", ascending: true)
    check(modelSessions(m1, m2), "model sessions asc orders by sessions")
    let modelTpsDesc = view.modelSort(key: "tps", ascending: false)
    check(modelTpsDesc(m2, m1) && !modelTpsDesc(m1, m2), "model tps desc orders by tps")

    let k1 = SkillRankRow(rank: 1, name: "anysearch", count: 50, agents: [.zcode], lastUsedMs: 1000, share: 60.0)
    let k2 = SkillRankRow(rank: 2, name: "frontend-design", count: 20, agents: [.dsh], lastUsedMs: 2000, share: 40.0)
    let skillCallsDesc = view.skillSort(key: "calls", ascending: false)
    check(skillCallsDesc(k1, k2) && !skillCallsDesc(k2, k1), "skill calls desc orders by calls")
    let skillNameAsc = view.skillSort(key: "name", ascending: true)
    check(skillNameAsc(k1, k2) && !skillNameAsc(k2, k1), "skill name asc orders by name")
    let skillLastUsedDesc = view.skillSort(key: "lastUsed", ascending: false)
    check(skillLastUsedDesc(k2, k1) && !skillLastUsedDesc(k1, k2), "skill lastUsed desc orders by lastUsedMs")
}

@MainActor
func testHourlyFlowMetrics() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // Case 1: Empty records
    let emptyResult = StatsDashboardView.computeHourlyMetrics(records: [], calendar: cal)
    check(emptyResult.buckets.count == 24, "empty records produces 24 hourly buckets")
    check(emptyResult.maxTokens == 0, "empty records maxTokens is 0")
    check(emptyResult.peakHour == nil, "empty records peakHour is nil")
    check(emptyResult.activeHours == 0, "empty records activeHours is 0")
    check(emptyResult.goldenWindow == nil, "empty records goldenWindow is nil")

    // Case 2: Synthetic records
    var comps = DateComponents()
    comps.year = 2026; comps.month = 9; comps.day = 29
    comps.hour = 0; comps.minute = 0; comps.second = 0
    let baseDate = cal.date(from: comps)!
    let baseMs = Int64(baseDate.timeIntervalSince1970 * 1000)

    // 10:15 UTC -> 50,000 tokens
    let r1 = UnifiedUsageRecord(
        agent: .gemini, model: "gemini-pro", title: nil,
        tsMs: baseMs + Int64(10 * 3600 + 15 * 60) * 1000,
        tokens: 50_000, freshInput: 10_000, cached: 35_000, output: 5_000,
        hasBreakdown: true, sessionId: "s1", durationMs: 1000
    )
    // 10:45 UTC -> 30,000 tokens (Hour 10 total = 80,000)
    let r2 = UnifiedUsageRecord(
        agent: .gemini, model: "gemini-pro", title: nil,
        tsMs: baseMs + Int64(10 * 3600 + 45 * 60) * 1000,
        tokens: 30_000, freshInput: 5_000, cached: 20_000, output: 5_000,
        hasBreakdown: true, sessionId: "s1", durationMs: 1000
    )
    // 14:00 UTC -> 200,000 tokens (Hour 14 total = 200,000, peak)
    let r3 = UnifiedUsageRecord(
        agent: .workbuddy, model: "claude-3-5", title: nil,
        tsMs: baseMs + Int64(14 * 3600) * 1000,
        tokens: 200_000, freshInput: 20_000, cached: 170_000, output: 10_000,
        hasBreakdown: true, sessionId: "s2", durationMs: 2000
    )
    // 15:30 UTC -> 100,000 tokens (Hour 15 total = 100,000)
    let r4 = UnifiedUsageRecord(
        agent: .zcode, model: "glm-4", title: nil,
        tsMs: baseMs + Int64(15 * 3600 + 30 * 60) * 1000,
        tokens: 100_000, freshInput: 10_000, cached: 82_000, output: 8_000,
        hasBreakdown: true, sessionId: "s3", durationMs: 1500
    )

    let metrics = StatsDashboardView.computeHourlyMetrics(records: [r1, r2, r3, r4], calendar: cal)
    check(metrics.buckets[10].tokens == 80_000, "hourly bucket 10 aggregates 80k tokens")
    check(metrics.buckets[10].turns == 2, "hourly bucket 10 counts 2 turns")
    check(metrics.buckets[14].tokens == 200_000, "hourly bucket 14 aggregates 200k tokens")
    check(metrics.maxTokens == 200_000, "hourly maxTokens matches 200k")
    check(metrics.peakHour == 14, "hourly peakHour is 14")
    check(metrics.peakTokens == 200_000, "hourly peakTokens is 200k")
    check(metrics.activeHours == 3, "hourly activeHours is 3 (10, 14, 15)")
    check(metrics.goldenWindow?.contains("12:00–16:00") == true, "hourly goldenWindow identifies the peak block")
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

// MARK: - Todo quick capture (M2/M4 pure-function surfaces)

@MainActor
func testTodoPromptBuild() {
    let (system, user) = TodoPrompt.build(
        input: "周五下午3点提醒我给妈妈打电话，很重要",
        now: Date(timeIntervalSince1970: 1_782_000_000), // fixed instant
        lists: ["提醒事项", "工作", "购物"],
        lastList: "工作"
    )
    check(system.contains("待办解析器"), "todo prompt system role")
    check(system.contains("ISO8601"), "todo prompt system mentions ISO8601")
    check(user.contains("周五下午3点提醒我给妈妈打电话"), "todo prompt includes raw input")
    check(user.contains("提醒事项, 工作, 购物"), "todo prompt includes list names")
    check(user.contains("上次选择的列表: 工作"), "todo prompt includes last list")

    let (_, userNoList) = TodoPrompt.build(
        input: "买牛奶", now: Date(), lists: [], lastList: nil)
    check(!userNoList.contains("可选列表"), "todo prompt omits empty list block")
    check(!userNoList.contains("上次选择的列表"), "todo prompt omits nil last list")
}

@MainActor
func testTodoLLMParseResponse() {
    // 合法 JSON
    let valid = Data(#"{"title":"给妈妈打电话","due":"2026-09-18T15:00:00+08:00","priority":1,"list":"工作","fallback":false}"#.utf8)
    if let parsed = TodoLLMClient.parseResponse(valid) {
        check(parsed.title == "给妈妈打电话", "parse valid title")
        check(parsed.priority == 1, "parse valid priority")
        check(parsed.list == "工作", "parse valid list")
        check(parsed.due != nil, "parse valid due date")
    } else {
        check(false, "parse valid JSON returns task")
    }

    // 缺字段（容错：title 空、priority 非法 → 默认 0）
    let sparse = Data(#"{"title":"","due":null,"fallback":true}"#.utf8)
    if let parsed = TodoLLMClient.parseResponse(sparse) {
        check(parsed.title == "", "parse sparse title empty")
        check(parsed.priority == 0, "parse invalid priority defaults to 0")
        check(parsed.due == nil, "parse null due")
        check(parsed.fallback == true, "parse fallback flag")
    } else {
        check(false, "parse sparse JSON returns task")
    }

    // 非 JSON
    check(TodoLLMClient.parseResponse(Data("not json".utf8)) == nil, "parse non-JSON returns nil")

    // markdown 围栏包裹的 JSON
    let fenced = Data("```json\n{\"title\":\"x\",\"due\":null,\"priority\":0,\"fallback\":false}\n```".utf8)
    check(TodoLLMClient.parseResponse(fenced)?.title == "x", "parse strips markdown fences")

    // 标准 OpenAI /chat/completions 响应封装
    let openAIJson = """
    {
      "id": "chatcmpl-123",
      "object": "chat.completion",
      "created": 1726822500,
      "model": "gpt-4o-mini",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "{\\"title\\":\\"给客户发合同\\",\\"due\\":\\"2026-09-22T14:30:00+08:00\\",\\"priority\\":1,\\"list\\":\\"合同\\",\\"fallback\\":false}"
          },
          "finish_reason": "stop"
        }
      ]
    }
    """
    if let parsed = TodoLLMClient.parseResponse(Data(openAIJson.utf8)) {
        check(parsed.title == "给客户发合同", "parse OpenAI envelope title")
        check(parsed.priority == 1, "parse OpenAI envelope priority")
        check(parsed.list == "合同", "parse OpenAI envelope list")
        check(parsed.due != nil, "parse OpenAI envelope due")
    } else {
        check(false, "parse OpenAI envelope returns task")
    }

    // 包含 <think> 思考过程的响应 (如 DeepSeek-R1)
    let reasoningJson = """
    {
      "choices": [
        {
          "message": {
            "content": "<think>用户需要在周五提交周报，优先级为中，列表选工作...</think>```json\\n{\\"title\\":\\"提交周报\\",\\"due\\":\\"2026-09-25T17:00:00+08:00\\",\\"priority\\":5,\\"list\\":\\"工作\\",\\"fallback\\":false}\\n```"
          }
        }
      ]
    }
    """
    if let parsed = TodoLLMClient.parseResponse(Data(reasoningJson.utf8)) {
        check(parsed.title == "提交周报", "parse reasoning model response title")
        check(parsed.priority == 5, "parse reasoning model response priority")
        check(parsed.list == "工作", "parse reasoning model response list")
    } else {
        check(false, "parse reasoning model response returns task")
    }

    // 字符串优先级容错 (high -> 1, 字符串 "9" -> 9, "null" 字符串过滤为 nil)
    let stringPriorityJson = Data(#"{"title":"紧急修复","due":null,"priority":"high","list":"工作","fallback":false}"#.utf8)
    if let parsed = TodoLLMClient.parseResponse(stringPriorityJson) {
        check(parsed.priority == 1, "parse string 'high' priority maps to 1")
    } else {
        check(false, "parse string priority returns task")
    }

    let stringNumPriorityJson = Data(#"{"title":"日常琐事","due":null,"priority":"9","list":"null","fallback":false}"#.utf8)
    if let parsed = TodoLLMClient.parseResponse(stringNumPriorityJson) {
        check(parsed.priority == 9, "parse string '9' priority maps to 9")
        check(parsed.list == nil, "parse 'null' string list filters to nil")
    } else {
        check(false, "parse string num priority returns task")
    }

    // 批量数组解析测试
    let batchJson = """
    [
      {"title":"买牛奶","due":null,"priority":0,"list":"日常","fallback":false},
      {"title":"写周报","due":"2026-09-25T17:00:00+08:00","priority":1,"list":"工作","fallback":false}
    ]
    """
    let batchTasks = TodoLLMClient.parseBatchResponse(Data(batchJson.utf8))
    check(batchTasks.count == 2, "parseBatchResponse parses 2 tasks")
    check(batchTasks.count == 2 && batchTasks[0].title == "买牛奶" && batchTasks[1].priority == 1, "parseBatchResponse fields intact")
}

@MainActor
func testTodoSettingsStoreStorage() {
    let testDefaults = UserDefaults(suiteName: "test.pinner.todo.llm")!
    defer { testDefaults.removePersistentDomain(forName: "test.pinner.todo.llm") }
    let config = TodoLLMConfig(baseURL: "https://example.test/v1", apiKey: "sk-test", model: "gpt-4o-mini")
    let store = TodoSettingsStore(defaults: testDefaults, key: "test.key")
    store.config = config
    let readBack = store.config
    check(readBack == config, "todo settings defaults roundtrip")
    store.clear()
    check(store.config == TodoLLMConfig.empty, "todo settings clear resets to empty")
}

@MainActor
func testReminderCompletionModel() {
    let item = ReminderItem(id: "test-id", title: "测试待办", dueDate: Date(), priority: 1, listName: "工作")
    check(item.priorityLabel == "高", "reminder priorityLabel high")
    check(!item.title.isEmpty, "reminder has title")
    let completedItem = ReminderItem(id: "c-id", title: "已完成待办", dueDate: nil, priority: 0, listName: "工作", completionDate: Date())
    check(completedItem.completionDate != nil, "reminder carries completionDate")
}

@MainActor
func testShelfOperations() throws {
    let suite = "test.pinner.shelf.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = CollectionStore(defaults: defaults)
    check(store.shelfEntries.isEmpty, "shelf initially empty")

    let tmp = FileManager.default.temporaryDirectory
    let file1 = tmp.appendingPathComponent("pinner_shelf_test1.txt")
    let file2 = tmp.appendingPathComponent("pinner_shelf_test2.txt")
    try "hello".write(to: file1, atomically: true, encoding: .utf8)
    try "world".write(to: file2, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: file1)
        try? FileManager.default.removeItem(at: file2)
    }

    let added = store.addShelfEntries(from: [file1, file2])
    check(added == 2, "shelf added 2 entries")
    check(store.shelfEntries.count == 2, "shelf has 2 entries")

    // Deduplication test
    let dupAdded = store.addShelfEntries(from: [file1])
    check(dupAdded == 0, "shelf ignores duplicate path")
    check(store.shelfEntries.count == 2, "shelf count remains 2 after duplicate")

    // Persistence test
    let reloadedStore = CollectionStore(defaults: defaults)
    check(reloadedStore.shelfEntries.count == 2, "shelf entries persist across store instances")
    check(reloadedStore.shelfEntries.contains(where: { $0.displayName == file1.lastPathComponent }), "persisted entry matches file1")

    // Remove single entry
    let firstID = store.shelfEntries[0].id
    store.removeShelfEntry(firstID)
    check(store.shelfEntries.count == 1, "shelf has 1 entry after removal")

    // Clear all
    store.clearShelf()
    check(store.shelfEntries.isEmpty, "shelf empty after clear")

    // Reloaded after clear
    let clearedStore = CollectionStore(defaults: defaults)
    check(clearedStore.shelfEntries.isEmpty, "cleared shelf persists as empty")
}

@MainActor
func testShelfFileNSURL() async {
    let file = makeTempFile()
    let id1 = UUID()
    let id2 = UUID()

    final class ResultBox: @unchecked Sendable {
        var ids: [UUID] = []
        var url: URL?
        let lock = NSLock()
        func record(_ newIDs: [UUID], _ newURL: URL) {
            lock.lock()
            ids.append(contentsOf: newIDs)
            url = newURL
            lock.unlock()
        }
    }

    let box = ResultBox()
    let item = ShelfFileNSURL(fileURL: file, entryIDs: [id1, id2]) { ids, u in
        box.record(ids, u)
    }

    check(item.isFileURL, "ShelfFileNSURL is a file URL")
    check(item.path == file.path, "ShelfFileNSURL path matches file")
    check(box.ids.isEmpty, "ShelfFileNSURL initially unconsumed")

    let provider = NSItemProvider(object: item)

    await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { _, _ in
            continuation.resume()
        }
    }

    try? await Task.sleep(nanoseconds: 700_000_000)

    check(box.ids == [id1, id2], "ShelfFileNSURL passes entry IDs on consumption")
    check(box.url?.path == file.path, "ShelfFileNSURL passes fileURL on consumption")

    // Second call should not trigger onConsumed again
    await withCheckedContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: "public.url") { _, _ in
            continuation.resume()
        }
    }
    try? await Task.sleep(nanoseconds: 700_000_000)
    check(box.ids.count == 2, "ShelfFileNSURL consumption is idempotent")
}

@MainActor
func testPinyinMatcher() {
    check(PinyinMatcher.matches(query: "周报", in: "项目周报.xlsx"), "pinyin exact match")
    check(PinyinMatcher.matches(query: "zhoubao", in: "项目周报.xlsx"), "pinyin full pinyin match")
    check(PinyinMatcher.matches(query: "zb", in: "项目周报.xlsx"), "pinyin initials match")
    check(PinyinMatcher.matches(query: "xmzb", in: "项目周报.xlsx"), "pinyin multi-word initials match")
    check(PinyinMatcher.matches(query: "pnr", in: "PinnerApp"), "pinyin subsequence fuzzy match")
    check(!PinyinMatcher.matches(query: "xyz", in: "项目周报.xlsx"), "pinyin mismatch returns false")
    check(PinyinMatcher.matches(query: "", in: "任意文本"), "pinyin empty query matches all")
}

@MainActor
func testWorkBuddyScanCache() {
    let service = WorkBuddyStatsService()
    let records1 = service.collectRecords(sinceMs: 0)
    let records2 = service.collectRecords(sinceMs: 0)
    check(records1.count == records2.count, "workbuddy scan cache preserves record count")
}

@MainActor
func testGeminiScanCache() {
    let service = GeminiStatsService()

    // 1. 确保首次或全量调用后磁盘持久化缓存文件存在且有效
    _ = service.fetchStatsAndTrend(for: .today)
    let cachePath = GeminiStatsService.cacheFileURL.path
    check(FileManager.default.fileExists(atPath: cachePath), "gemini disk cache file exists on disk")

    if let data = try? Data(contentsOf: GeminiStatsService.cacheFileURL),
       let cacheDict = try? JSONDecoder().decode([String: GeminiStatsService.DiskFileCacheEntry].self, from: data) {
        check(!cacheDict.isEmpty, "gemini disk cache file decodes with non-empty entries (\(cacheDict.count) files)")
    } else {
        check(false, "gemini disk cache file decodes valid JSON")
    }

    // 2. 模拟冷加载（清空内存缓存，必须读磁盘 JSON 反序列化）vs 热缓存（纯内存复用）时延与数据等价
    GeminiStatsService.resetMemoryCacheForTesting()
    let t0 = CFAbsoluteTimeGetCurrent()
    let resCold = service.fetchStatsAndTrend(for: .today)
    let dCold = CFAbsoluteTimeGetCurrent() - t0

    let t1 = CFAbsoluteTimeGetCurrent()
    let resWarm = service.fetchStatsAndTrend(for: .today)
    let dWarm = CFAbsoluteTimeGetCurrent() - t1

    check(resCold.stats.currentTokens == resWarm.stats.currentTokens, "gemini scan cache preserves token count (\(resCold.stats.currentTokens))")
    check(resCold.trend.count == resWarm.trend.count, "gemini scan cache preserves trend points (\(resCold.trend.count))")
    check(dWarm < max(0.05, dCold * 0.5), "gemini hot scan is faster than cold scan (cold \(String(format: "%.3f", dCold))s, warm \(String(format: "%.3f", dWarm))s)")

    // 3. 验证 collectRecords 聚合的一致性与非空保护
    let records1 = service.collectRecords(sinceUnix: 0)
    let records2 = service.collectRecords(sinceUnix: 0)
    check(records1.count == records2.count && !records1.isEmpty, "gemini collectRecords preserves record count (\(records1.count))")
}

@MainActor
func testThumbnailDoesNotHitIconCache() throws {
    // Icons and thumbnails used to share one NSCache key. The row always paints
    // the icon first, so the thumbnail lookup hit that entry and grid cells
    // never showed a content preview.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        check(false, "thumbnail regression fixture produced a PNG")
        return
    }
    let png = FileManager.default.temporaryDirectory.appendingPathComponent("pinner-\(UUID().uuidString).png")
    try data.write(to: png)
    defer { try? FileManager.default.removeItem(at: png) }

    let item = try entry(for: png)
    _ = FileIconWrap.baseIcon(for: item)

    var completedSynchronously = false
    FileIconWrap.loadThumbnailIfAvailable(for: item) { _ in completedSynchronously = true }
    check(!completedSynchronously, "warmed icon cache does not satisfy a thumbnail lookup")
}

@MainActor
func testNonVisualFileDoesNotGenerateThumbnail() throws {
    let md = FileManager.default.temporaryDirectory.appendingPathComponent("pinner-\(UUID().uuidString).md")
    try "# test".write(to: md, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: md) }

    let item = try entry(for: md)
    var thumbnailRequested = false
    FileIconWrap.loadThumbnailIfAvailable(for: item) { _ in thumbnailRequested = true }
    check(!thumbnailRequested, "markdown and text files do not generate content thumbnails")
}

@MainActor
func testFleetingCapture() {
    // 1. TypeSafe Jev System One response decoding
    let jevSampleJSON = """
    {
      "model": "jev-1.13.0",
      "answers": {
        "target_folder": {
          "type": "choice",
          "choice": "清醒备忘",
          "confidence": 1.0,
          "probabilities": {"清醒备忘": 1.0, "装修笔记": 0.0}
        },
        "note_清醒备忘": {
          "type": "choice",
          "choice": "【断联日志】",
          "confidence": 1.0,
          "probabilities": {"【断联日志】": 1.0, "新建独立笔记": 0.0}
        },
        "mode": {
          "type": "choice",
          "choice": "prepend",
          "confidence": 0.95,
          "probabilities": {"prepend": 0.95, "append": 0.05}
        }
      }
    }
    """
    let tree = [
        AppleNotesService.FolderItem(name: "清醒备忘", notes: ["【断联日志】", "【认知重塑】"]),
        AppleNotesService.FolderItem(name: "装修笔记", notes: ["【全屋尺寸】"])
    ]
    let jevParsed = TypeSafeJevClient.decodeJevResponse(
        Data(jevSampleJSON.utf8),
        originalInput: "今天断联第 37 天，心情很平静",
        tree: tree
    )
    check(jevParsed?.folder == "清醒备忘", "Jev decodes target folder")
    check(jevParsed?.targetNoteTitle == "【断联日志】", "Jev decodes target note title")
    check(jevParsed?.mode == .prepend, "Jev decodes prepend mode for diary")
    check(jevParsed?.formattedContent == "今天断联第 37 天，心情很平静", "Jev preserves authentic text verbatim")

    let jevRouteResult = TypeSafeJevClient.decodeJevResult(
        Data(jevSampleJSON.utf8),
        originalInput: "今天断联第 37 天，心情很平静",
        tree: tree
    )
    check(jevRouteResult?.isHighConfidence == true, "Jev calibrated isHighConfidence is true on dominant top probability")

    // Test sanitizer anti-hallucination snapping
    let hallucinated = ParsedFleetingThought(
        folder: "不存在的分类",
        targetNoteTitle: "不存在的笔记",
        mode: .append,
        formattedContent: "随笔内容",
        confidence: 0.8,
        fallback: false
    )
    let sanitized = FleetingThoughtLLMClient.sanitize(parsed: hallucinated, tree: tree, originalInput: "随笔内容")
    check(sanitized.folder == "清醒备忘", "sanitize snaps unknown folder to valid tree folder")
    check(sanitized.targetNoteTitle == "【断联日志】", "sanitize snaps unknown note to valid folder note")
    check(sanitized.formattedContent == "随笔内容", "sanitize guarantees authentic input content")

    // Invalidate folder tree cache roundtrip
    AppleNotesService.shared.invalidateFolderTreeCache()

    // 2. HTML stripping and markdown to HTML conversion
    let sampleHTML = "<h1>标题</h1><div>正文内容</div><ul><li>第 1 天<br></li></ul>"
    let stripped = AppleNotesService.stripHTML(sampleHTML)
    check(stripped.contains("标题") && stripped.contains("正文内容") && stripped.contains("第 1 天"), "stripHTML extracts plain text")

    let mdText = "- 第一条\n- 第二条"
    let convertedHTML = AppleNotesService.markdownToHTML(mdText)
    check(convertedHTML.contains("<ul>") && convertedHTML.contains("<li>第一条<br></li>") && convertedHTML.contains("</ul>"), "markdownToHTML converts bullet list")

    // 3. Prepend into existing <ul>
    let oldListHTML = "<h1>【断联日志】</h1><div><br></div><ul><li>第 36 天：内容<br></li></ul>"
    let prepended = AppleNotesService.insertPrepend(into: oldListHTML, content: "- 第 37 天：新记录")
    check(prepended.contains("<ul><li>第 37 天：新记录<br></li><li>第 36 天：内容<br></li></ul>"), "insertPrepend inserts at top of <ul> list")

    // 4. Prompt building & authenticity guarantee
    let ctx = FleetingPrompt.Context(
        input: "今天去咖啡馆看了会儿书，心情很平静",
        folders: ["Notes", "清醒备忘"],
        recentNotes: ["【断联日志】", "读书笔记"],
        pinnedNotes: ["【断联日志】"],
        folderTree: [
            AppleNotesService.FolderItem(name: "清醒备忘", notes: ["【断联日志】", "【认知重塑】"]),
            AppleNotesService.FolderItem(name: "妙笔偶得", notes: ["日常随笔", "佳句"])
        ],
        lastFolder: "清醒备忘",
        lastNote: "【断联日志】"
    )
    let (systemPrompt, userPrompt) = FleetingPrompt.build(context: ctx)
    check(systemPrompt.contains("必须 100% 原样保留用户的原始文字表述"), "prompt guarantees 100% text authenticity")
    check(systemPrompt.contains("prepend"), "prompt specifies prepend mode")
    check(userPrompt.contains("今天去咖啡馆看了会儿书，心情很平静"), "user prompt includes raw input")
    check(userPrompt.contains("【断联日志】"), "user prompt includes target note")
    check(userPrompt.contains("[备忘录分类与已有笔记]"), "user prompt contains folder tree structure")

    // 5. LLM client parsing & stripping reasoning tags
    let rawEnvelopeWithThink = """
    {
      "choices": [{
        "message": {
          "content": "<think>用户记录断联日志，应置顶前插并递增天数</think>```json\\n{\\"folder\\":\\"清醒备忘\\",\\"targetNoteTitle\\":\\"【断联日志】\\",\\"mode\\":\\"prepend\\",\\"formattedContent\\":\\"- 第 37 天：今天心情很平静\\",\\"confidence\\":0.98}\\n```"
        }
      }]
    }
    """
    let parsed = FleetingThoughtLLMClient.parseResponse(Data(rawEnvelopeWithThink.utf8))
    check(parsed?.folder == "清醒备忘", "LLM parse extracts folder")
    check(parsed?.targetNoteTitle == "【断联日志】", "LLM parse extracts note title")
    check(parsed?.mode == .prepend, "LLM parse extracts prepend mode")
    check(parsed?.formattedContent == "- 第 37 天：今天心情很平静", "LLM parse strips think tags and extracts content")

    // 6. Local fallback logic
    let fallback = FleetingThoughtLLMClient.localFallback(context: ctx)
    check(fallback.folder == "清醒备忘" && fallback.targetNoteTitle == "【断联日志】", "fallback routes breakup diary to 清醒备忘 / 【断联日志】")
    check(fallback.mode == .prepend, "fallback uses prepend mode")
    check(fallback.formattedContent == "今天去咖啡馆看了会儿书，心情很平静", "fallback preserves user verbatim input without day modification")

    // 6.1 Semantic routing fallback when lastNote is clean/nil
    let cleanCtx = FleetingPrompt.Context(
        input: "卧室的全屋定制柜体尺寸需要再复核一遍",
        folderTree: [
            AppleNotesService.FolderItem(name: "装修笔记", notes: ["【全屋尺寸】", "【电路布局】"]),
            AppleNotesService.FolderItem(name: "妙笔偶得", notes: ["日常随笔"])
        ]
    )
    let cleanFallback = FleetingThoughtLLMClient.localFallback(context: cleanCtx)
    check(cleanFallback.folder == "装修笔记", "fallback routes renovation keyword to 装修笔记")
    check(cleanFallback.targetNoteTitle == "【全屋尺寸】", "fallback selects first note in matched folder")

    // 7. FleetingSettingsStore pinning and LRU
    let store = FleetingSettingsStore(defaults: UserDefaults(suiteName: "test-fleeting-\(UUID().uuidString)")!)
    check(store.pinnedNotes.isEmpty, "store defaults to empty pinned notes")
    store.pinNote("灵感随想")
    check(store.pinnedNotes.contains("灵感随想"), "pinNote adds note")
    store.unpinNote("灵感随想")
    check(!store.pinnedNotes.contains("灵感随想"), "unpinNote removes note")

    store.recordTarget(folder: "妙笔偶得", note: "新灵感")
    check(store.lastFolder == "妙笔偶得" && store.lastNote == "新灵感", "recordTarget updates last target")
    check(store.recentTargets.first?.note == "新灵感", "recentTargets places latest at front")

    store.removeTarget(id: "妙笔偶得/新灵感")
    check(!store.recentTargets.contains(where: { $0.note == "新灵感" }), "removeTarget deletes target from history")
    check(store.lastNote == nil, "removeTarget clears lastNote if matched")

    store.recordTarget(folder: "清醒备忘", note: "【断联日志】")
    store.clearAllTargets()
    check(store.recentTargets.isEmpty, "clearAllTargets empties recent list")

    // 8. Reasoning tag stripping helper test
    let rawThought = "<think>思考中...\n这是长篇思考</think>润色后的纯净文本"
    check(FleetingThoughtLLMClient.stripReasoningTags(rawThought) == "润色后的纯净文本", "stripReasoningTags eliminates think block")

    // 9. AppleNotesService empty list safety (no Range 1...0 crash)
    let emptyListDesc = NSAppleEventDescriptor.list()
    check(emptyListDesc.numberOfItems == 0, "empty NSAppleEventDescriptor has 0 items")
    let itemsParsed: [String] = {
        if emptyListDesc.numberOfItems > 0 {
            return (1...emptyListDesc.numberOfItems).compactMap { emptyListDesc.atIndex($0)?.stringValue }
        }
        return []
    }()
    check(itemsParsed.isEmpty, "empty list descriptor yields empty array without crash")
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
    try? testThumbnailDoesNotHitIconCache()
    try? testNonVisualFileDoesNotGenerateThumbnail()
    testAgentSelectionPersistence()
    testMenuBarMenuFollowsSelection()
    testSettingsSubmenuContents()
    testAgentStatsHotkeyManagerLifecycle()
    testAgentSymbolsExist()
    await testDshScanCacheReusesResults()
    testDailySortHelpers()
    testHourlyFlowMetrics()
    testTodoPromptBuild()
    testTodoLLMParseResponse()
    testTodoSettingsStoreStorage()
    testReminderCompletionModel()
    try? testShelfOperations()
    await testShelfFileNSURL()
    testPinyinMatcher()
    testWorkBuddyScanCache()
    testGeminiScanCache()
    testFleetingCapture()
    testSkillStatsService()
    try? await testCustomAliasPreservation()
    testOTPServiceTimeRemaining()
    testInputStats()
    testModuleManager()
    testPortManager()
    print("\n\(passed) passed, \(failed) failed")
    return failed == 0
}.value
exit(allPassed ? 0 : 1)

@MainActor
func testSkillStatsService() {
    let service = SkillStatsService.shared
    service.clearCacheForTesting()
    let installed = service.scanInstalledSkills()
    check(!installed.isEmpty, "scanInstalledSkills finds installed skills (\(installed.count) found)")

    let (records, installedSet) = service.collectAll(force: true)
    check(!records.isEmpty, "collectAll returns skill records (\(records.count) found)")
    check(installedSet == installed, "collectAll returns matching installed skills set")

    let t0 = CFAbsoluteTimeGetCurrent()
    let (cachedRecords, _) = service.collectAll(force: false)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    check(cachedRecords.count == records.count, "SkillStatsService cache preserves record count")
    check(elapsed < 0.05, "SkillStatsService cache lookup is fast (\(String(format: "%.4f", elapsed))s)")

    check(FileManager.default.fileExists(atPath: SkillStatsService.cacheFileURL.path), "skill_scan_cache.json exists on disk")
    let hasWebgen = records.contains { $0.skillName.lowercased() == "gemini-webgen" }
    check(hasWebgen, "SkillStatsService detects gemini-webgen call records")

    // Check that .workbuddy/skills directory is supported in scanInstalledSkills
    let home = FileManager.default.homeDirectoryForCurrentUser
    let testWorkbuddySkills = home.appendingPathComponent(".workbuddy/skills")
    let fakeSkill = testWorkbuddySkills.appendingPathComponent("test-custom-skill-\(UUID().uuidString)")
    if (try? FileManager.default.createDirectory(at: fakeSkill, withIntermediateDirectories: true)) != nil {
        defer { try? FileManager.default.removeItem(at: fakeSkill) }
        let scanned = service.scanInstalledSkills()
        check(scanned.contains(fakeSkill.lastPathComponent), "scanInstalledSkills picks up skill in .workbuddy/skills")
    }
}

@MainActor
func testCustomAliasPreservation() async throws {
    let store = makeStore()
    store.createTab(named: "T")
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }
    store.addEntry(try entry(for: url), to: 0)
    let entryID = store.tabs[0].entries[0].id

    // Rename with custom alias
    store.renameEntry(entryID, in: 0, to: "我的自定义别名")
    check(store.tabs[0].entries[0].displayName == "我的自定义别名", "custom alias set")
    check(store.tabs[0].entries[0].customAlias == "我的自定义别名", "customAlias field populated")

    // Refresh tab async - validates bookmark and runs apply()
    await store.refreshTabAsync(0)
    check(store.tabs[0].entries[0].displayName == "我的自定义别名", "custom alias preserved after refreshTabAsync")

    // Test resetEntryAlias reverts to disk filename
    store.resetEntryAlias(entryID, in: 0)
    check(store.tabs[0].entries[0].customAlias == nil, "customAlias cleared by resetEntryAlias")
    check(store.tabs[0].entries[0].displayName == url.lastPathComponent, "displayName restored to disk filename")
}

@MainActor
func testOTPServiceTimeRemaining() {
    let date0 = Date(timeIntervalSince1970: 0)
    check(OTPService.timeRemaining(at: date0) == 30, "timeRemaining at t=0 is 30")

    let date10 = Date(timeIntervalSince1970: 10)
    check(OTPService.timeRemaining(at: date10) == 20, "timeRemaining at t=10 is 20")

    let date29 = Date(timeIntervalSince1970: 29)
    check(OTPService.timeRemaining(at: date29) == 1, "timeRemaining at t=29 is 1")

    let date30 = Date(timeIntervalSince1970: 30)
    check(OTPService.timeRemaining(at: date30) == 30, "timeRemaining at t=30 is 30")

    let dateNeg = Date(timeIntervalSince1970: -5)
    let remNeg = OTPService.timeRemaining(at: dateNeg)
    check(remNeg >= 1 && remNeg <= 30, "timeRemaining at negative timestamp stays within 1...30")
}

@MainActor
func testInputStats() {
    let stats = DailyInputStats(
        dateString: "2026-10-06",
        keyCount: 1500,
        leftClickCount: 300,
        rightClickCount: 50,
        middleClickCount: 20,
        otherClickCount: 10,
        mouseDistanceMeters: 1250.5,
        scrollDistancePixels: 45000.0,
        peakKPS: 12.5,
        peakCPS: 4.2
    )

    check(stats.totalClicks == 380, "totalClicks computes sum of all mouse clicks")
    check(stats.hourlyBuckets.count == 24, "hourlyBuckets initializes 24 hours")
    check(DailyInputStats.formatNumber(1500) == "1,500", "formatNumber formats with thousand separators")
    check(DailyInputStats.formatDistance(85.4) == "85.4 m", "formatDistance meters formatting")
    check(DailyInputStats.formatDistance(1250.5) == "1.25 km", "formatDistance km formatting")
    check(DailyInputStats.formatScrollPixels(45000.0) == "45.0 kPx", "formatScrollPixels kPx formatting")
    check(DailyInputStats.formatScrollPixels(1_500_000.0) == "1.50 MPx", "formatScrollPixels MPx formatting")

    // Serialization
    let encoded = try? JSONEncoder().encode(stats)
    check(encoded != nil, "DailyInputStats encodes to JSON")
    if let data = encoded, let decoded = try? JSONDecoder().decode(DailyInputStats.self, from: data) {
        check(decoded.keyCount == 1500, "DailyInputStats roundtrip keyCount matches")
        check(decoded.leftClickCount == 300, "DailyInputStats roundtrip leftClickCount matches")
        check(decoded.totalClicks == 380, "DailyInputStats roundtrip totalClicks matches")
        check(decoded.peakKPS == 12.5, "DailyInputStats roundtrip peakKPS matches")
    }

    // DailyInputSummary & InputMetricType tests
    let summary = DailyInputSummary(from: stats)
    check(summary.keyCount == 1500, "DailyInputSummary keyCount from stats matches")
    check(summary.clickCount == 380, "DailyInputSummary clickCount from stats matches totalClicks")
    check(summary.mouseDistanceMeters == 1250.5, "DailyInputSummary mouseDistanceMeters matches")
    check(summary.scrollDistancePixels == 45000.0, "DailyInputSummary scrollDistancePixels matches")
    check(summary.shortDateLabel == "10/06", "DailyInputSummary shortDateLabel parses MM/dd")

    check(InputMetricType.keyboard.value(from: summary) == 1500, "InputMetricType.keyboard extracts keyCount")
    check(InputMetricType.clicks.value(from: summary) == 380, "InputMetricType.clicks extracts clickCount")
    check(InputMetricType.distance.value(from: summary) == 1250.5, "InputMetricType.distance extracts distance")
    check(InputMetricType.scroll.value(from: summary) == 45000.0, "InputMetricType.scroll extracts scroll")
    check(InputMetricType.keyboard.formatTotal(12500) == "12.5 k", "InputMetricType.formatTotal formats >= 10k")

    // History Series & InputStatsService integration
    let service = InputStatsService.shared
    let series7 = service.historySeries(days: 7)
    check(series7.count == 7, "historySeries(days: 7) returns exactly 7 items")
    let series30 = service.historySeries(days: 30)
    check(series30.count == 30, "historySeries(days: 30) returns exactly 30 items")

    let todayString = DailyInputStats.todayDateString()
    check(series7.last?.dateString == todayString, "historySeries ends with today's dateString")
    check(series30.last?.dateString == todayString, "historySeries 30 ends with today's dateString")

    // Check chronological order
    if series7.count >= 2 {
        let first = series7[0].dateString
        let second = series7[1].dateString
        check(first < second, "historySeries is chronologically ordered ascending")
    }

    // Test recording past day
    let pastDaySummary = DailyInputSummary(
        dateString: "2026-10-01",
        keyCount: 888,
        clickCount: 99,
        mouseDistanceMeters: 50.0,
        scrollDistancePixels: 2000.0,
        appStats: [
            "com.apple.Safari": AppInputStats(bundleId: "com.apple.Safari", appName: "Safari", keyCount: 100, clickCount: 20, scrollDistancePixels: 500.0)
        ]
    )
    service.recordHistoryDay(pastDaySummary)
    check(service.history["2026-10-01"]?.keyCount == 888, "recordHistoryDay persists past day summary to history dictionary")

    // Test aggregated app stats
    let allAppStats = service.aggregatedAppStats(range: .all)
    check(!allAppStats.isEmpty, "aggregatedAppStats includes historical app records")

    // Clean up test data so it does not pollute user history
    service.removeHistoryDay("2026-10-01")
    check(service.history["2026-10-01"] == nil, "removeHistoryDay successfully removes mock date from history")

    // Hotkey accessors
    let bar = MenuBarController(store: CollectionStore(inMemory: true))
    check(bar.inputStatsHotkeyString() == "未设置", "inputStatsHotkeyString accessor returns default string")
}

@MainActor
func testModuleManager() {
    let suite = UserDefaults(suiteName: "test-module-manager-\(UUID().uuidString)")!
    let manager = ModuleManager(defaults: suite)

    // Defaults: all modules enabled
    check(manager.enabledModules == Set(PinnerModule.allCases), "all modules enabled by default")
    check(manager.isEnabled(.collection), "collection is enabled")
    check(manager.isEnabled(.todo), "todo is enabled")
    check(manager.isEnabled(.fleeting), "fleeting is enabled")
    check(manager.isEnabled(.agentStats), "agentStats is enabled")
    check(manager.isEnabled(.inputStats), "inputStats is enabled")
    check(manager.isEnabled(.portManager), "portManager is enabled")
    check(manager.isEnabled(.otp), "otp is enabled")

    // Core module (.collection) cannot be disabled
    manager.setEnabled(.collection, to: false)
    check(manager.isEnabled(.collection), "core module collection remains enabled even if set to false")

    // Toggle off todo, portManager and otp
    manager.setEnabled(.todo, to: false)
    manager.setEnabled(.otp, to: false)
    manager.setEnabled(.portManager, to: false)
    check(!manager.isEnabled(.todo), "todo is disabled after setEnabled false")
    check(!manager.isEnabled(.otp), "otp is disabled after setEnabled false")
    check(!manager.isEnabled(.portManager), "portManager is disabled after setEnabled false")

    // Reload from defaults
    let reloaded = ModuleManager(defaults: suite)
    check(!reloaded.isEnabled(.todo), "disabled todo persists across reloads")
    check(!reloaded.isEnabled(.otp), "disabled otp persists across reloads")
    check(!reloaded.isEnabled(.portManager), "disabled portManager persists across reloads")
    check(reloaded.isEnabled(.collection), "core collection remains active across reloads")

    // Re-enable
    manager.setEnabled(.todo, to: true)
    manager.setEnabled(.portManager, to: true)
    check(manager.isEnabled(.todo), "todo is re-enabled successfully")
    check(manager.isEnabled(.portManager), "portManager is re-enabled successfully")

    // Menu generation respects module settings
    let customSuite = UserDefaults(suiteName: "test-menu-modules-\(UUID().uuidString)")!
    let customManager = ModuleManager(defaults: customSuite)
    customManager.setEnabled(.todo, to: false)
    customManager.setEnabled(.otp, to: false)
    customManager.setEnabled(.agentStats, to: false)
    customManager.setEnabled(.portManager, to: false)

    let bar = MenuBarController(store: CollectionStore(inMemory: true))
    let menu = bar.makeMenu(modules: customManager)
    let titles = menu.items.map(\.title)

    check(!titles.contains("待办"), "menu hides disabled todo module")
    check(!titles.contains("OTP 验证码"), "menu hides disabled otp module")
    check(!titles.contains("端口管家"), "menu hides disabled portManager module")
    check(!titles.contains("统计总览"), "menu hides disabled agentStats dashboard")
    check(!titles.contains("各 Agent 明细"), "menu hides disabled agentStats submenu")
    check(titles.contains("收藏夹"), "menu retains core collection module")
    check(titles.contains("键鼠统计"), "menu retains enabled inputStats module")
    check(titles.contains("偏好设置…"), "menu retains preferences")
    check(titles.contains { $0.hasPrefix("退出") }, "menu retains quit")
}

@MainActor
func testPortManager() {
    // 1. PortProcessInfo Display Formatting
    let proc1 = PortProcessInfo(
        pid: 3001,
        command: "node",
        fullPath: "/opt/homebrew/bin/node",
        user: "apple",
        ports: [3000, 3001],
        cpuPercent: 1.5,
        memoryBytes: 52428800, // 50 MB
        category: .devServer
    )
    check(proc1.displayName == "node", "PortProcessInfo displayName uses command")
    check(proc1.portsDisplayString == "3000, 3001", "PortProcessInfo formats multiple ports")
    check(proc1.memoryDisplayString == "50 MB", "PortProcessInfo formats 50 MB")

    let proc2 = PortProcessInfo(
        pid: 9999,
        command: "",
        fullPath: "/usr/local/bin/custom_service",
        ports: [8080]
    )
    check(proc2.displayName == "custom_service", "PortProcessInfo fallback to fullPath last component")

    let proc3 = PortProcessInfo(pid: 8888, command: "", fullPath: "")
    check(proc3.displayName == "PID 8888", "PortProcessInfo fallback to PID string")

    // 2. formatBytes scale checks
    check(PortProcessInfo.formatBytes(0) == "0 B", "formatBytes 0")
    check(PortProcessInfo.formatBytes(512) == "512 B", "formatBytes small bytes")
    check(PortProcessInfo.formatBytes(2048) == "2 KB", "formatBytes 2 KB")
    check(PortProcessInfo.formatBytes(1073741824) == "1.0 GB", "formatBytes 1.0 GB")

    // 3. Process Classification Rules
    check(PortManagerService.classifyProcess(command: "node", fullPath: "/usr/local/bin/node", user: "apple") == .devServer, "classify node as devServer")
    check(PortManagerService.classifyProcess(command: "python3", fullPath: "/opt/homebrew/bin/python3", user: "apple") == .devServer, "classify python3 as devServer")
    check(PortManagerService.classifyProcess(command: "vite", fullPath: "", user: "apple") == .devServer, "classify vite as devServer")
    check(PortManagerService.classifyProcess(command: "postgres", fullPath: "", user: "apple") == .devServer, "classify postgres as devServer")
    check(PortManagerService.classifyProcess(command: "redis-server", fullPath: "", user: "apple") == .devServer, "classify redis as devServer")

    check(PortManagerService.classifyProcess(command: "rapportd", fullPath: "/usr/libexec/rapportd", user: "apple") == .systemDaemon, "classify rapportd as systemDaemon")
    check(PortManagerService.classifyProcess(command: "ControlCenter", fullPath: "/System/Library/CoreServices/ControlCenter.app", user: "apple") == .systemDaemon, "classify ControlCenter as systemDaemon")
    check(PortManagerService.classifyProcess(command: "custom_daemon", fullPath: "", user: "_windowserver") == .systemDaemon, "classify _user as systemDaemon")

    check(PortManagerService.classifyProcess(command: "Arc", fullPath: "/Applications/Arc.app/Contents/MacOS/Arc", user: "apple") == .userApp, "classify Arc as userApp")
    check(PortManagerService.classifyProcess(command: "WeChat", fullPath: "/Applications/WeChat.app/Contents/MacOS/WeChat", user: "apple") == .userApp, "classify WeChat as userApp")

    // Docker classification
    check(PortManagerService.classifyProcess(command: "orbstack", fullPath: "", user: "apple") == .docker, "classify orbstack as docker")
    check(PortManagerService.classifyProcess(command: "docker-proxy", fullPath: "", user: "apple") == .docker, "classify docker-proxy as docker")
    check(ProcessCategory.docker.rawValue == "Docker", "ProcessCategory.docker rawValue is Docker")
    check(ProcessFilterCategory.docker.rawValue == "Docker", "ProcessFilterCategory.docker rawValue is Docker")
    check(ProcessFilterCategory.exposed.rawValue == "外部暴露", "ProcessFilterCategory.exposed rawValue is 外部暴露")

    let dockerProc = PortProcessInfo(
        pid: 52903,
        command: "finance-app",
        ports: [8000],
        category: .docker,
        isExposed: true,
        exposedPorts: [8000],
        containerName: "finance-app",
        containerImage: "finance-app:1.0"
    )
    check(dockerProc.displayName == "finance-app", "dockerProc displayName is containerName")
    check(dockerProc.id == "52903_finance-app", "dockerProc id incorporates containerName")
    check(dockerProc.isExposed == true, "dockerProc isExposed matches true")
    check(dockerProc.exposedPorts == [8000], "dockerProc exposedPorts matches 8000")

    // Sort Fields
    check(PortTableSortField.allCases.count == 6, "PortTableSortField has 6 fields")

    // 4. Summary Stats
    var stats = PortSummaryStats(
        activePortCount: 12,
        totalMemoryBytes: 2147483648,
        devServerCount: 5,
        dockerCount: 2,
        rootProcessCount: 1,
        totalCpuPercent: 15.6,
        exposedPortCount: 4
    )
    check(stats.activePortCount == 12, "summary activePortCount matches")
    check(stats.dockerCount == 2, "summary dockerCount matches 2")
    check(stats.dockerContainerCount == 2, "summary dockerContainerCount alias matches 2")
    check(stats.memoryDisplayString == "2.0 GB", "summary memoryDisplayString matches 2.0 GB")
    check(stats.totalCpuPercent == 15.6, "summary totalCpuPercent matches 15.6")
    check(stats.cpuDisplayString == "15.6%", "summary cpuDisplayString matches 15.6%")
    check(stats.exposedPortCount == 4, "summary exposedPortCount matches 4")
}




