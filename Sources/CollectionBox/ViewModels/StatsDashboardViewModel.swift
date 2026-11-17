import Combine
import Foundation

/// Owns the **data plane** of the Agent 总览 dashboard: the record cache, the
/// multi-agent scan orchestration, the derived snapshot, and the AI 周报 runner.
///
/// Why this exists: `StatsDashboardView` had grown to ~2.7k lines with 30+ `@State`
/// properties, where a 300-line snapshot build and a 6-way concurrent scan sat
/// next to colour constants. Splitting the data plane out keeps the view to
/// layout + local UI state, and makes the scan/snapshot logic reachable from a
/// test without standing up SwiftUI.
///
/// Boundary with the view:
/// - **Here** — cached records, refresh progress, snapshot, weekly insight.
/// - **In the view** — range tabs, custom date pickers, search text, sort keys,
///   hover tooltips, sheet presentation. Those are handed over as `Query`.
///
/// Nested row/snapshot types stay declared on `StatsDashboardView` on purpose:
/// `AgentWeeklyInsightService`, `AgentWeeklyInsightSheet` and the test runner all
/// reference `StatsDashboardView.DashboardSnapshot` / `.DayRow` today, so moving
/// them would be a rename-only refactor with zero behavioural value.
@MainActor
public final class StatsDashboardViewModel: ObservableObject {

    /// The slice of view state a snapshot build depends on.
    struct Query: Sendable, Equatable {
        var sinceMs: Int64
        var untilMs: Int64
        var isDayLocked: Bool
        var selectedAgentFilter: StatsAgent?
        var sessionSortKey: String
        var sessionSortAsc: Bool

        static let empty = Query(
            sinceMs: 0,
            untilMs: Int64.max,
            isDayLocked: false,
            selectedAgentFilter: nil,
            sessionSortKey: "tokens",
            sessionSortAsc: false
        )
    }

    // MARK: - Cached records

    /// One full scan; every panel slices this in memory instead of re-reading
    /// session files per range change.
    @Published var allRecords: [UnifiedUsageRecord] = []
    @Published var allSkillRecords: [SkillRecord] = []
    @Published var installedSkills: Set<String> = []
    @Published var loadedAgents: Set<StatsAgent> = []

    // MARK: - Refresh progress

    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var refreshProgress = 0
    @Published var refreshTotal = 0
    @Published var refreshingAgents: Set<StatsAgent> = []
    /// Fast cache hits finish in milliseconds; dimming for that long would
    /// flicker on every auto-refresh tick, so dimming is delayed (see
    /// `scheduleStaleDim`).
    @Published var dimStaleData = false

    // MARK: - Derived snapshot

    @Published var snapshot: StatsDashboardView.DashboardSnapshot?

    // MARK: - AI weekly insight

    @Published var weeklyInsight: AgentWeeklyInsight?
    @Published var weeklyInsightSnapshot: StatsDashboardView.DashboardSnapshot?
    @Published var weeklyWorkflowDigest: WorkflowObservationDigest?
    @Published var isGeneratingInsight = false
    @Published var weeklyInsightError: String?

    // MARK: - Internal bookkeeping

    /// Bumped on every scan so a superseded run can recognise itself and drop
    /// its result instead of overwriting fresher data.
    private var refreshToken = 0
    private var pendingPublishToken: Int?
    private var staleDimTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var scanWatchdog: Task<Void, Never>?
    private var currentQuery: Query = .empty

    private let service = StatsDashboardService.shared

    public init() {}

    // MARK: - Agent selection (single source: the shared selection object)

    var enabledAgents: Set<StatsAgent> { StatsAgentSelection.shared.enabledAgents }

    var visibleAgents: [StatsAgent] {
        StatsAgent.allCases.filter { enabledAgents.contains($0) }
    }

    // MARK: - Scanning

    /// Scans every enabled agent concurrently.
    ///
    /// - Parameters:
    ///   - force: ignore per-agent caches (manual refresh).
    ///   - supersede: let a newer scan win even while one is in flight. Used when
    ///     the enabled-agent set changes, because the running scan no longer
    ///     covers the right agents.
    ///   - query: UI state to rebuild the snapshot with once the scan lands.
    func reload(force: Bool = false, supersede: Bool = false, query: Query) {
        currentQuery = query
        let agentsToScan = visibleAgents
        AppLog.stats.debug("reload agents=\(agentsToScan.count, privacy: .public) force=\(force, privacy: .public) supersede=\(supersede, privacy: .public) refreshing=\(self.isRefreshing, privacy: .public) records=\(self.allRecords.count, privacy: .public)")
        guard !agentsToScan.isEmpty else {
            AppLog.stats.notice("reload aborted: no agent enabled")
            loadedAgents = Set(visibleAgents)
            return
        }

        // A scan is already running: a second pass would only duplicate work,
        // and whichever finishes last wins — a cached result could land on top
        // of a fresh one.
        if isRefreshing && !force && !supersede {
            AppLog.stats.debug("reload skipped: scan in flight")
            return
        }

        if force {
            loadedAgents = []
        }

        refreshToken &+= 1
        let token = refreshToken
        isRefreshing = true
        refreshProgress = 0
        refreshTotal = agentsToScan.count
        refreshingAgents = Set(agentsToScan)
        scheduleStaleDim()
        startScanWatchdog(token: token)

        let keep = Set(agentsToScan)
        allRecords.removeAll { !keep.contains($0.agent) }

        let service = self.service

        Task.detached(priority: .userInitiated) { [weak self] in
            let startedAt = Date()
            async let skillsTask = SkillStatsService.shared.collectAll(force: force)
            let collected = await withTaskGroup(of: (StatsAgent, [UnifiedUsageRecord]).self) { group -> [(StatsAgent, [UnifiedUsageRecord])] in
                for agent in agentsToScan {
                    group.addTask {
                        let agentRecords = service.collect(agent: agent, sinceMs: 0, force: force)
                        return (agent, agentRecords)
                    }
                }
                var items: [(StatsAgent, [UnifiedUsageRecord])] = []
                for await item in group {
                    items.append(item)
                    AppLog.stats.debug("scan finished \(item.0.rawValue, privacy: .public) records=\(item.1.count, privacy: .public)")
                    await MainActor.run {
                        guard let self else { return }
                        // A superseded scan must not touch the shared progress state.
                        guard token == self.refreshToken else { return }
                        self.refreshingAgents.remove(item.0)
                        self.refreshProgress += 1
                    }
                }
                return items
            }
            let (skills, installed) = await skillsTask
            AppLog.stats.debug("scan complete agents=\(collected.count, privacy: .public) skills=\(skills.count, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s")
            await MainActor.run {
                guard let self else { return }
                // A newer refresh superseded this one; its result is the current truth.
                guard token == self.refreshToken else {
                    AppLog.stats.debug("scan result dropped: superseded")
                    return
                }
                for (agent, recs) in collected {
                    self.allRecords.removeAll { $0.agent == agent }
                    self.allRecords.append(contentsOf: recs)
                    self.loadedAgents.insert(agent)
                }
                self.allSkillRecords = skills
                self.installedSkills = installed
                self.pendingPublishToken = token
                // Publish with whatever range the user is looking at *now*: the
                // scan takes a second or two, and a range switch in the meantime
                // must not be overwritten by the window captured at scan start.
                self.updateSnapshot(query: self.currentQuery)
            }
        }
    }

    /// Fast refreshes (cache hits) finish in milliseconds; dimming the data
    /// area for that long would just flicker every auto-refresh tick.
    private func scheduleStaleDim() {
        staleDimTask?.cancel()
        staleDimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.dimStaleData = true
        }
    }

    func cancelStaleDim() {
        staleDimTask?.cancel()
        staleDimTask = nil
        dimStaleData = false
    }

    /// Last-resort recovery for a scan that never reports back.
    ///
    /// `isRefreshing` is also the guard that drops every subsequent reload, so a
    /// scan stuck in a blocking call (a hung `ps`, an unreachable network volume
    /// under a skills directory, a stall inside `ScanGate`) would leave the panel
    /// saying 正在扫描… until the app is relaunched. This trips that state open
    /// after the budget below and lets the next tick start a clean scan.
    private func startScanWatchdog(token: Int) {
        scanWatchdog?.cancel()
        scanWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.isRefreshing, token == self.refreshToken else { return }
            AppLog.stats.error("scan watchdog: no result after 45s, releasing refresh state")
            self.isRefreshing = false
            self.refreshingAgents = []
            self.refreshTotal = max(self.refreshTotal, self.refreshProgress)
            self.cancelStaleDim()
        }
    }

    // MARK: - Snapshot

    /// Rebuilds the derived snapshot off the main actor.
    ///
    /// The sorted/merged rows are expensive (alias folding, day bucketing,
    /// per-session aggregation), so this runs detached and publishes only when
    /// the build is complete — that is also when the refresh is marked done,
    /// otherwise the UI would claim fresh data while still showing old numbers.
    func updateSnapshot(query: Query) {
        currentQuery = query
        snapshotTask?.cancel()
        let records = allRecords
        let skillRecords = allSkillRecords
        let installed = installedSkills
        let enabled = enabledAgents
        let visible = visibleAgents
        let selectedFilter = query.selectedAgentFilter
        let sinceMs = query.sinceMs
        let untilMs = query.untilMs
        let dayLocked = query.isDayLocked
        let sessionKey = query.sessionSortKey
        let sessionAsc = query.sessionSortAsc
        // Snapshot the alias rules on the main actor: the detached task below
        // must not read observable state.
        let table = ModelAliasService.shared.table

        snapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snap = StatsDashboardView.buildSnapshot(
                records: records,
                skillRecords: skillRecords,
                installedSkills: installed,
                enabledAgents: enabled,
                visibleAgents: visible,
                selectedAgentFilter: selectedFilter,
                effectiveSinceMs: sinceMs,
                effectiveUntilMs: untilMs,
                isDayLocked: dayLocked,
                sessionSortKey: sessionKey,
                sessionSortAsc: sessionAsc,
                aliasTable: table
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.snapshot = snap
                // The refresh is only "done" once the new numbers are on screen:
                // the snapshot build is asynchronous, so announcing it earlier
                // would claim fresh data while the old one is still showing.
                guard let pending = self.pendingPublishToken, pending == self.refreshToken else { return }
                self.pendingPublishToken = nil
                self.lastUpdated = Date()
                self.isRefreshing = false
                self.refreshingAgents = []
                self.refreshProgress = self.refreshTotal
                self.scanWatchdog?.cancel()
                self.scanWatchdog = nil
                self.cancelStaleDim()
                AppLog.stats.debug("published days=\(snap.dayRows.count, privacy: .public) tokens=\(snap.inRangeTotalTokens, privacy: .public) sessions=\(snap.allSessionsCount, privacy: .public)")
            }
        }
    }

    // MARK: - AI Weekly Insight

    /// - Parameter preferCurrentSnapshot: true when the on-screen range already
    ///   *is* the 7-day window with no day lock and no agent filter, so the
    ///   visible snapshot can be reused instead of rebuilding one.
    func buildWeeklyInsightSnapshot(preferCurrentSnapshot: Bool) -> StatsDashboardView.DashboardSnapshot? {
        if preferCurrentSnapshot, let snap = snapshot {
            return snap
        }
        guard !allRecords.isEmpty || snapshot != nil else { return nil }
        let d7SinceMs = Int64((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
        return StatsDashboardView.buildSnapshot(
            records: allRecords,
            skillRecords: allSkillRecords,
            installedSkills: installedSkills,
            enabledAgents: enabledAgents,
            visibleAgents: visibleAgents,
            selectedAgentFilter: nil,
            effectiveSinceMs: d7SinceMs,
            effectiveUntilMs: Int64.max,
            isDayLocked: false,
            sessionSortKey: "tokens",
            sessionSortAsc: false,
            aliasTable: ModelAliasService.shared.table
        )
    }

    func openWeeklyInsight(preferCurrentSnapshot: Bool) {
        let isFirstOpenInSession = (weeklyInsight == nil)
        weeklyInsightError = nil
        if isFirstOpenInSession {
            isGeneratingInsight = true
        }

        if let cached = AgentWeeklyInsightService.shared.getCachedInsight(),
           Date().timeIntervalSince(cached.createdAt) < 1800 {
            if isFirstOpenInSession {
                let records = allRecords
                let skillRecords = allSkillRecords
                let installed = installedSkills
                let enabled = enabledAgents
                let visible = visibleAgents
                let table = ModelAliasService.shared.table
                let fallbackSnap = snapshot
                Task { [weak self] in
                    async let digestTask = WorkflowDigestService.shared.collect7DayDigest()
                    let built = await Task.detached(priority: .userInitiated) { () -> StatsDashboardView.DashboardSnapshot? in
                        guard !records.isEmpty else { return nil }
                        let d7SinceMs = Int64((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
                        return StatsDashboardView.buildSnapshot(
                            records: records,
                            skillRecords: skillRecords,
                            installedSkills: installed,
                            enabledAgents: enabled,
                            visibleAgents: visible,
                            selectedAgentFilter: nil,
                            effectiveSinceMs: d7SinceMs,
                            effectiveUntilMs: Int64.max,
                            isDayLocked: false,
                            sessionSortKey: "tokens",
                            sessionSortAsc: false,
                            aliasTable: table
                        )
                    }.value
                    let digest = await digestTask
                    await MainActor.run {
                        guard let self else { return }
                        self.weeklyInsightSnapshot = built ?? fallbackSnap
                        self.weeklyWorkflowDigest = digest
                        self.weeklyInsight = cached
                        self.isGeneratingInsight = false
                    }
                }
            } else {
                if weeklyInsightSnapshot == nil {
                    weeklyInsightSnapshot = buildWeeklyInsightSnapshot(preferCurrentSnapshot: preferCurrentSnapshot) ?? snapshot
                }
                if weeklyWorkflowDigest == nil {
                    Task { [weak self] in
                        let digest = await WorkflowDigestService.shared.collect7DayDigest()
                        await MainActor.run { self?.weeklyWorkflowDigest = digest }
                    }
                }
                weeklyInsight = cached
                isGeneratingInsight = false
            }
        } else {
            generateWeeklyInsight(forceRefresh: true, preferCurrentSnapshot: preferCurrentSnapshot)
        }
    }

    func generateWeeklyInsight(forceRefresh: Bool, preferCurrentSnapshot: Bool = false) {
        if forceRefresh {
            weeklyInsight = nil
        }
        isGeneratingInsight = true
        weeklyInsightError = nil

        let records = allRecords
        let skillRecords = allSkillRecords
        let installed = installedSkills
        let enabled = enabledAgents
        let visible = visibleAgents
        let table = ModelAliasService.shared.table
        let fallbackSnap = snapshot

        Task { [weak self] in
            let startTime = Date()
            async let digestTask = WorkflowDigestService.shared.collect7DayDigest()
            let builtSnap = await Task.detached(priority: .userInitiated) { () -> StatsDashboardView.DashboardSnapshot? in
                guard !records.isEmpty else { return nil }
                let d7SinceMs = Int64((Date().timeIntervalSince1970 - 7 * 86400) * 1000)
                return StatsDashboardView.buildSnapshot(
                    records: records,
                    skillRecords: skillRecords,
                    installedSkills: installed,
                    enabledAgents: enabled,
                    visibleAgents: visible,
                    selectedAgentFilter: nil,
                    effectiveSinceMs: d7SinceMs,
                    effectiveUntilMs: Int64.max,
                    isDayLocked: false,
                    sessionSortKey: "tokens",
                    sessionSortAsc: false,
                    aliasTable: table
                )
            }.value

            let digest = await digestTask

            guard let snap = builtSnap ?? fallbackSnap else {
                await MainActor.run {
                    guard let self else { return }
                    self.weeklyInsightError = "账本数据正在加载中，请稍后重试"
                    self.isGeneratingInsight = false
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                self.weeklyInsightSnapshot = snap
                self.weeklyWorkflowDigest = digest
            }

            do {
                let insight = try await AgentWeeklyInsightService.shared.generateInsight(
                    snapshot: snap,
                    workflowDigest: digest,
                    forceRefresh: forceRefresh
                )
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed < 1.1 {
                    let remainNs = UInt64((1.1 - elapsed) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: remainNs)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.weeklyInsight = insight
                    self.isGeneratingInsight = false
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.weeklyInsightError = error.localizedDescription
                    self.isGeneratingInsight = false
                }
            }
        }
    }
}
