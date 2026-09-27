import SwiftUI

struct StatsDashboardView: View {
    enum DashRange: Int, CaseIterable, Identifiable {
        case today = 1, yesterday = -2, week = 7, month = 30, all = 0, custom = -1
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return "今天"
            case .yesterday: return "昨天"
            case .week: return "近 7 天"
            case .month: return "近 30 天"
            case .all: return "全部"
            case .custom: return "自定义"
            }
        }
    }

    struct RankRow: Identifiable, Sendable {
        let idx: Int; let name: String; let tokens: Int; let share: Double
        var id: Int { idx }
    }

    struct DayRow: Identifiable, Sendable {
        let id: String
        let date: String
        let total: Int
        let fresh: Int
        let cached: Int
        let output: Int
        let sessions: Int
    }

    struct SessionRow: Identifiable, Sendable {
        let id: String
        let title: String
        let agent: StatsAgent
        let tokens: Int
        let turns: Int
    }

    struct ModelRankRow: Identifiable, Sendable {
        let id: String
        let name: String
        let agents: String
        let tokens: Int
        let sessions: Int
    }

    struct DashboardSnapshot: Sendable {
        let d7Tokens: Int
        let d30Tokens: Int
        let dailyAvgTokens: Int
        let allSessionsCount: Int
        let topModels: [RankRow]
        let startedText: String
        let activeDaysCount: Int
        let heatmapColumns: [[Date]]
        let heatmapDaily: [Date: Int]
        let heatmapMaxDay: Int
        let trendDays: [Date]
        let trendValues: [Int]
        let trendMax: Int

        let inRangeTotalTokens: Int
        let freshInput: Int
        let cachedInput: Int
        let outputTokens: Int
        let cacheHitRate: Double
        let hasCodexNotice: Bool
        let agentTokens: [StatsAgent: Int]
        let agentModelCounts: [StatsAgent: Int]
        let dayRows: [DayRow]
        let sessionRows: [SessionRow]
        let modelRankRows: [ModelRankRow]
    }

    @State private var range: DashRange = .today
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var allRecords: [UnifiedUsageRecord] = []   // one full scan; all views slice in memory
    @State private var loadedAgents: Set<StatsAgent> = []
    @State private var scannedAgents: Set<StatsAgent> = []
    @State private var lastUpdated: Date?
    @State private var detailTab: Int = 0
    @State private var dailySortKey: String = "date"
    @State private var dailySortAsc: Bool = false
    @State private var sessionSortKey: String = "tokens"
    @State private var sessionSortAsc: Bool = false
    @State private var modelSortKey: String = "tokens"
    @State private var modelSortAsc: Bool = false
    @State private var heatHoverText: String?
    @State private var trendHoverText: String?
    @State private var snapshot: DashboardSnapshot?
    @State private var selectedAgentFilter: StatsAgent? = nil
    @ObservedObject private var agentSelection = StatsAgentSelection.shared
    private var enabledAgents: Set<StatsAgent> { agentSelection.enabledAgents }
    private let service = StatsDashboardService.shared

    private let agentColor: [StatsAgent: Color] = [
        .codex: .purple, .gemini: .blue, .workbuddy: .green, .zcode: .orange, .dsh: .teal
    ]

    private var visibleAgents: [StatsAgent] {
        StatsAgent.allCases.filter { enabledAgents.contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            mainArea
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 760)
        .onAppear { reload() }
        .onChange(of: range) { _, _ in updateSnapshot() }
        .onChange(of: customStart) { _, _ in if range == .custom { updateSnapshot() } }
        .onChange(of: customEnd) { _, _ in if range == .custom { updateSnapshot() } }
        .onChange(of: enabledAgents) { _, _ in reload() }
    }

    // MARK: - Range Window

    private var effectiveSinceMs: Int64 {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .today: return Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
        case .yesterday:
            let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
            return Int64(cal.startOfDay(for: yesterday).timeIntervalSince1970 * 1000)
        case .week: return Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000)
        case .month: return Int64((now.timeIntervalSince1970 - 30 * 86400) * 1000)
        case .all: return 0
        case .custom: return Int64(cal.startOfDay(for: customStart).timeIntervalSince1970 * 1000)
        }
    }

    private var effectiveUntilMs: Int64 {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .yesterday:
            return Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
        case .custom:
            return Int64((customEnd.timeIntervalSince1970 + 86400) * 1000) // inclusive end day
        default:
            return Int64(now.timeIntervalSince1970 * 1000)
        }
    }

    private var inRange: [UnifiedUsageRecord] {
        allRecords.filter { enabledAgents.contains($0.agent) && $0.tsMs >= effectiveSinceMs && $0.tsMs <= effectiveUntilMs }
    }

    // MARK: - Sidebar (all-time view)

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                quickStats
                modelRanking
                startedInfo
                sidebarHeatmapCard
                sidebarTrendCard
            }
            .padding(14)
        }
    }

    private var quickStats: some View {
        HStack(spacing: 6) {
            miniStat(WorkBuddyStats.formatTokens(snapshot?.d7Tokens ?? 0), "7天")
            miniStat(WorkBuddyStats.formatTokens(snapshot?.d30Tokens ?? 0), "30天")
            miniStat(WorkBuddyStats.formatTokens(snapshot?.dailyAvgTokens ?? 0), "日均")
            miniStat("\(snapshot?.allSessionsCount ?? 0)", "会话")
        }
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: Design.micro)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusS)
    }

    private var modelRanking: some View {
        let rows = snapshot?.topModels ?? []
        return VStack(alignment: .leading, spacing: 7) {
            if rows.isEmpty {
                placeholder(loadedAgents.count < visibleAgents.count ? "正在扫描…" : "暂无数据")
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text("\(row.idx)")
                            .font(.system(size: Design.micro, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(row.name)
                            .font(.system(size: Design.caption))
                            .lineLimit(1).truncationMode(.middle)
                            .help("\(row.name)：\(WorkBuddyStats.formatTokens(row.tokens)) tokens（\(String(format: "%.1f", row.share))%）")
                        Spacer()
                        Text(WorkBuddyStats.formatTokens(row.tokens))
                            .font(.system(size: Design.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", row.share))
                            .font(.system(size: Design.caption, weight: .bold, design: .rounded))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private var startedInfo: some View {
        HStack {
            Text("起始 \(snapshot?.startedText ?? "—")").font(.system(size: Design.micro)).foregroundStyle(.secondary)
            Spacer()
            Text("活跃 \(snapshot?.activeDaysCount ?? 0) 天").font(.system(size: Design.micro)).foregroundStyle(.secondary)
        }
    }

    /// Half-year contribution grid, Sun-first rows, green scale — all-time.
    private var sidebarHeatmapCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("活动热力图").font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let heatHoverText {
                    Text(heatHoverText).font(.system(size: Design.micro, weight: .medium)).foregroundStyle(.primary)
                } else {
                    Text(timeZoneLabel).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                }
            }
            if snapshot?.heatmapColumns.isEmpty ?? true {
                placeholder(loadedAgents.count < visibleAgents.count ? "正在扫描…" : "暂无数据")
            } else {
                contributionGrid
                HStack(spacing: 3) {
                    Spacer()
                    Text("少").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                    ForEach([0.08, 0.25, 0.45, 0.65, 0.9], id: \.self) { a in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(a == 0.08 ? Color.secondary.opacity(a) : Color.green.opacity(a))
                            .frame(width: 10, height: 10)
                    }
                    Text("多").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private var timeZoneLabel: String {
        let seconds = TimeZone.current.secondsFromGMT() / 3600
        return seconds >= 0 ? "UTC+\(String(format: "%02d:00", seconds))" : "UTC-\(String(format: "%02d:00", -seconds))"
    }

    private var contributionGrid: some View {
        GeometryReader { geo in
            let cal = Calendar.current
            let maxWeeks = 26
            let rowLabelWidth: CGFloat = 16
            let gap: CGFloat = 2
            let usable = max(120, geo.size.width - rowLabelWidth)
            let cell = max(5, floor((usable - CGFloat(maxWeeks - 1) * gap) / CGFloat(maxWeeks)))

            let columns = snapshot?.heatmapColumns ?? []
            let daily = snapshot?.heatmapDaily ?? [:]
            let maxDay = snapshot?.heatmapMaxDay ?? 0

            let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "M/d"
            let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "M月"
            let rowNames = ["日", "一", "二", "三", "四", "五", "六"]

            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: gap) {
                    Text("").frame(width: rowLabelWidth)
                    ForEach(columns.indices, id: \.self) { ci in
                        VStack(spacing: 0) {
                            if ci == 0 || (columns[ci].first != nil && columns[ci - 1].first != nil && cal.component(.month, from: columns[ci][0]) != cal.component(.month, from: columns[ci - 1][0])) {
                                Text(monthFormatter.string(from: columns[ci][0]))
                                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { ri in
                            Text(rowNames[ri]).font(.system(size: 8)).foregroundStyle(.tertiary)
                                .frame(width: rowLabelWidth, height: cell, alignment: .trailing)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(columns.indices, id: \.self) { ci in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { ri in
                                    if ri < columns[ci].count {
                                        let day = columns[ci][ri]
                                        let tokens = daily[day] ?? 0
                                        let hoverText = tokens > 0
                                            ? "\(dayFormatter.string(from: day))：\(WorkBuddyStats.formatTokens(tokens)) tokens"
                                            : "\(dayFormatter.string(from: day))：无用量"
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(heatColor(tokens: tokens, maxDay: maxDay))
                                            .frame(width: cell, height: cell)
                                            .contentShape(Rectangle())
                                            .help(hoverText)
                                            .onHover { hovering in
                                                if hovering { heatHoverText = hoverText }
                                                else if heatHoverText == hoverText { heatHoverText = nil }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 96)
    }

    private func heatColor(tokens: Int, maxDay: Int) -> Color {
        guard tokens > 0, maxDay > 0 else { return Color.secondary.opacity(0.08) }
        let ratio = Double(tokens) / Double(maxDay)
        switch ratio {
        case ..<0.25: return Color.green.opacity(0.25)
        case ..<0.5: return Color.green.opacity(0.45)
        case ..<0.75: return Color.green.opacity(0.65)
        default: return Color.green.opacity(0.9)
        }
    }

    /// Daily bar chart over the last 30 days (all-time daily totals), green.
    private var sidebarTrendCard: some View {
        let days = snapshot?.trendDays ?? []
        let values = snapshot?.trendValues ?? []
        let maxV = snapshot?.trendMax ?? 0
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量趋势").font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trendHoverText {
                    Text(trendHoverText).font(.system(size: Design.micro, weight: .medium)).foregroundStyle(.primary)
                }
            }
            if values.isEmpty {
                placeholder(loadedAgents.count < visibleAgents.count ? "正在扫描…" : "暂无数据")
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(values.indices, id: \.self) { i in
                        let h: CGFloat = maxV > 0 ? CGFloat(CGFloat(values[i]) / CGFloat(maxV)) * 72 : 0
                        let hoverText = "\(df.string(from: days[i]))：\(WorkBuddyStats.formatTokens(values[i])) tokens"
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.green.opacity(values[i] > 0 ? 0.85 : 0.15))
                            .frame(height: max(3, h))
                            .help(hoverText)
                            .onHover { hovering in
                                if hovering { trendHoverText = hoverText }
                                else if trendHoverText == hoverText { trendHoverText = nil }
                            }
                    }
                }
                .frame(height: 74)
                HStack {
                    Text(df.string(from: days.first ?? Date())).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(df.string(from: days.last ?? Date())).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    // MARK: - Main Area (range view)

    private var mainArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rangeTabs
                totalTokenHeader
                stackedShareBar
                agentCards
                detailTabs
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeTabs: some View {
        HStack(spacing: 12) {
            Picker("时间范围", selection: $range) {
                ForEach(DashRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if range == .custom {
                DatePicker("从", selection: $customStart, displayedComponents: .date)
                    .font(.system(size: Design.caption))
                DatePicker("到", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                    .font(.system(size: Design.caption))
            }
            Spacer()
            agentVisibilityMenu
            if let last = lastUpdated {
                Text("刷新于 \(last, style: .time)").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
            Button(action: { reload(force: true) }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("刷新").accessibilityLabel("刷新")
        }
    }

    /// Which agents the dashboard aggregates. Persisted; the last remaining
    /// agent cannot be switched off.
    private var agentVisibilityMenu: some View {
        Menu {
            ForEach(StatsAgent.allCases, id: \.self) { agent in
                Toggle(agent.label, isOn: agentBinding(agent))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                Text("Agent").font(.system(size: Design.caption, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: 76, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择参与统计的 Agent").accessibilityLabel("选择参与统计的 Agent")
    }

    private func agentBinding(_ agent: StatsAgent) -> Binding<Bool> {
        Binding(
            get: { enabledAgents.contains(agent) },
            set: { on in
                if !on && enabledAgents.count <= 1 { return }
                if on { agentSelection.setEnabled(agent, to: true) }
                else { agentSelection.setEnabled(agent, to: false) }
            }
        )
    }

    private var totalTokenHeader: some View {
        let total = snapshot?.inRangeTotalTokens ?? 0
        let fresh = snapshot?.freshInput ?? 0
        let output = snapshot?.outputTokens ?? 0
        let hitRate = snapshot?.cacheHitRate ?? 0.0
        let hasNotice = snapshot?.hasCodexNotice ?? false

        return VStack(spacing: 8) {
            Text("TOKEN 总量").font(.system(size: Design.caption, weight: .medium)).foregroundStyle(.secondary)
                .tracking(2)
            Text(intervalString(total))
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.4)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("净输入 (未缓存)")
                        .font(.system(size: Design.caption))
                        .foregroundStyle(.secondary)
                    Text(intervalString(fresh))
                        .font(.system(size: Design.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.secondary.opacity(0.08)))
                .help("当前时间范围内未命中缓存、全价计费的首次输入 Token 总量")

                HStack(spacing: 4) {
                    Text("模型输出")
                        .font(.system(size: Design.caption))
                        .foregroundStyle(.secondary)
                    Text(intervalString(output))
                        .font(.system(size: Design.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.secondary.opacity(0.08)))
                .help("当前时间范围内模型生成的 Output Token 总量")

                HStack(spacing: 4) {
                    Text("缓存命中")
                        .font(.system(size: Design.caption))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", hitRate))
                        .font(.system(size: Design.caption, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.green.opacity(0.1)))
                .help("上下文缓存 (Prompt Cache) 命中比例，命中率越高越节省开销")
            }
            if hasNotice {
                Text("注：Codex 本地库仅记录总量，净输入/输出/缓存由其他 Agent 聚合")
                    .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
            if loadedAgents.count < visibleAgents.count {
                Text("正在扫描 \(visibleAgents.count - loadedAgents.count) 个 Agent…")
                    .font(.system(size: Design.caption)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func intervalString(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var stackedShareBar: some View {
        let grand = snapshot?.inRangeTotalTokens ?? 0
        let agentTokens = snapshot?.agentTokens ?? [:]
        return VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(visibleAgents, id: \.self) { agent in
                        let tokens = agentTokens[agent] ?? 0
                        RoundedRectangle(cornerRadius: 1)
                            .fill(agentColor[agent] ?? .gray)
                            .frame(width: grand > 0 ? max(2, geo.size.width * CGFloat(tokens) / CGFloat(grand) - 1) : 0)
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private var agentCards: some View {
        let grand = snapshot?.inRangeTotalTokens ?? 0
        let agentTokens = snapshot?.agentTokens ?? [:]
        let agentModels = snapshot?.agentModelCounts ?? [:]
        return HStack(spacing: 10) {
            ForEach(visibleAgents, id: \.self) { agent in
                let tokens = agentTokens[agent] ?? 0
                let models = agentModels[agent] ?? 0
                let share = grand > 0 ? Double(tokens) / Double(grand) * 100 : 0.0
                let isFiltered = selectedAgentFilter == agent
                let isDimmed = selectedAgentFilter != nil && !isFiltered

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: agent.symbolName).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(agentColor[agent] ?? .secondary)
                        Text(agent.label.uppercased())
                            .font(.system(size: Design.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isFiltered {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(agentColor[agent] ?? Color.accentColor)
                        } else if !loadedAgents.contains(agent) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    Text(String(format: "%.1f%%", share))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        Text("\(WorkBuddyStats.formatTokens(tokens)) tokens")
                            .font(.system(size: Design.caption, weight: .semibold))
                            .foregroundStyle(agentColor[agent] ?? .secondary)
                        Text("· \(models) 模型")
                            .font(.system(size: Design.caption)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .fill(isFiltered ? (agentColor[agent] ?? Color.accentColor).opacity(0.12) : Color.secondary.opacity(Design.slotAlpha))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .strokeBorder(agentColor[agent] ?? Color.accentColor, lineWidth: isFiltered ? 1.5 : 0)
                )
                .opacity(isDimmed ? 0.45 : 1.0)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if selectedAgentFilter == agent {
                            selectedAgentFilter = nil
                        } else {
                            selectedAgentFilter = agent
                        }
                        updateSnapshot()
                    }
                }
                .help(isFiltered ? "点击取消聚焦 \(agent.label)" : "点击聚焦筛选 \(agent.label) 的明细与排行")
            }
        }
    }

    // MARK: - Detail Tabs

    private var detailTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("明细", selection: $detailTab) {
                    Text("每日明细").tag(0)
                    Text("会话排行").tag(1)
                    Text("模型排行").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)

                if let filter = selectedAgentFilter {
                    Button {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedAgentFilter = nil
                            updateSnapshot()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: filter.symbolName)
                                .font(.system(size: 9))
                            Text("已聚焦：\(filter.label)")
                                .font(.system(size: Design.caption, weight: .medium))
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((agentColor[filter] ?? Color.accentColor).opacity(0.15)))
                        .foregroundStyle(agentColor[filter] ?? Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("点击取消聚焦，查看全部 Agent")
                }

                Spacer()

                if detailTab == 0 {
                    Button {
                        exportDailyCSV()
                    } label: {
                        Label("导出 CSV", systemImage: "square.and.arrow.down")
                            .font(.system(size: Design.caption, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("将每日明细导出为 CSV")
                }
            }

            if detailTab == 0 { dailyBreakdownTable } else if detailTab == 1 { sessionRankTable } else { modelRankTable }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private var dailyBreakdownTable: some View {
        let rows = (snapshot?.dayRows ?? []).sorted(by: dailySort(key: dailySortKey, ascending: dailySortAsc))

        return VStack(spacing: 0) {
            headerRow
            Divider()
            if rows.isEmpty {
                placeholder("所选范围内没有数据").padding(.vertical, 16)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text(row.date).font(.system(size: Design.caption)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(intervalString(row.total)).font(.system(size: Design.caption, weight: .semibold)).frame(width: 110, alignment: .trailing)
                        Text(intervalString(row.fresh)).font(.system(size: Design.caption)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                        Text(intervalString(row.output)).font(.system(size: Design.caption)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                        Text(intervalString(row.cached)).font(.system(size: Design.caption)).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                        Text("\(row.sessions)").font(.system(size: Design.caption)).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.5)
                }
            }
        }
    }

    func dailySort(key: String, ascending: Bool) -> (DayRow, DayRow) -> Bool {
        { a, b in
            switch key {
            case "total": return ascending ? a.total < b.total : a.total > b.total
            case "fresh": return ascending ? a.fresh < b.fresh : a.fresh > b.fresh
            case "output": return ascending ? a.output < b.output : a.output > b.output
            case "cached": return ascending ? a.cached < b.cached : a.cached > b.cached
            case "sessions": return ascending ? a.sessions < b.sessions : a.sessions > b.sessions
            default: return ascending ? a.date < b.date : a.date > b.date
            }
        }
    }

    private func sortHeader(_ title: String, key: String, current: String, ascending: Bool, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                if current == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(.system(size: Design.caption, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .trailing)
        .contentShape(Rectangle())
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortHeader("日期", key: "date", current: dailySortKey, ascending: dailySortAsc, action: toggleDailySortDate)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("合计", key: "total", current: dailySortKey, ascending: dailySortAsc, width: 110, action: { toggleDailySort("total") })
            sortHeader("净输入", key: "fresh", current: dailySortKey, ascending: dailySortAsc, width: 100, action: { toggleDailySort("fresh") })
                .help("未命中缓存的首次输入 Tokens (Codex 本地库仅提供总量)")
            sortHeader("输出", key: "output", current: dailySortKey, ascending: dailySortAsc, width: 100, action: { toggleDailySort("output") })
                .help("模型生成的 Output Tokens (Codex 本地库仅提供总量)")
            sortHeader("缓存", key: "cached", current: dailySortKey, ascending: dailySortAsc, width: 120, action: { toggleDailySort("cached") })
                .help("命中的上下文缓存 Tokens (Codex 本地库仅提供总量)")
            sortHeader("会话", key: "sessions", current: dailySortKey, ascending: dailySortAsc, width: 60, action: { toggleDailySort("sessions") })
        }
        .padding(.vertical, 4)
    }

    private func toggleDailySortDate() {
        if dailySortKey == "date" { dailySortAsc.toggle() }
        else { dailySortKey = "date"; dailySortAsc = false }
    }

    private func toggleDailySort(_ key: String) {
        if dailySortKey == key { dailySortAsc.toggle() }
        else { dailySortKey = key; dailySortAsc = false }
    }

    private var sessionRankTable: some View {
        let rows = (snapshot?.sessionRows ?? [])
            .sorted(by: sessionSort(key: sessionSortKey, ascending: sessionSortAsc))
            .prefix(30)
            .map { $0 }

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortHeader("会话", key: "title", current: sessionSortKey, ascending: sessionSortAsc, action: { toggleSessionSort("title") })
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Agent").font(.system(size: Design.caption, weight: .semibold)).frame(width: 90, alignment: .leading)
                sortHeader("Tokens", key: "tokens", current: sessionSortKey, ascending: sessionSortAsc, width: 110, action: { toggleSessionSort("tokens") })
                sortHeader("轮次", key: "turns", current: sessionSortKey, ascending: sessionSortAsc, width: 60, action: { toggleSessionSort("turns") })
            }
            .padding(.vertical, 4)
            Divider()
            if rows.isEmpty {
                placeholder("所选范围内没有数据").padding(.vertical, 16)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text(row.title).font(.system(size: Design.caption)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.agent.label).font(.system(size: Design.caption)).foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(intervalString(row.tokens)).font(.system(size: Design.caption, weight: .semibold))
                            .frame(width: 110, alignment: .trailing)
                        Text("\(row.turns)").font(.system(size: Design.caption)).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.5)
                }
            }
        }
    }

    func modelSort(key: String, ascending: Bool) -> (ModelRankRow, ModelRankRow) -> Bool {
        { a, b in
            switch key {
            case "name": return ascending ? a.name < b.name : a.name > b.name
            case "sessions": return ascending ? a.sessions < b.sessions : a.sessions > b.sessions
            default: return ascending ? a.tokens < b.tokens : a.tokens > b.tokens
            }
        }
    }

    private func toggleModelSort(_ key: String) {
        if modelSortKey == key { modelSortAsc.toggle() }
        else { modelSortKey = key; modelSortAsc = false }
    }

    // MARK: - CSV Export

    private func exportDailyCSV() {
        let rows = (snapshot?.dayRows ?? []).sorted { $0.date > $1.date }
        var csv = "日期,合计,净输入,输出,缓存,会话\n"
        for r in rows {
            csv += "\(r.date),\(r.total),\(r.fresh),\(r.output),\(r.cached),\(r.sessions)\n"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Pinner-每日明细-\(range.label).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func sessionSort(key: String, ascending: Bool) -> (SessionRow, SessionRow) -> Bool {
        { a, b in
            switch key {
            case "title": return ascending ? a.title < b.title : a.title > b.title
            case "turns": return ascending ? a.turns < b.turns : a.turns > b.turns
            default: return ascending ? a.tokens < b.tokens : a.tokens > b.tokens
            }
        }
    }

    private func toggleSessionSort(_ key: String) {
        if sessionSortKey == key { sessionSortAsc.toggle() }
        else { sessionSortKey = key; sessionSortAsc = false }
    }

    /// Cross-agent model ranking: merged by display name, share bar, tokens,
    /// sessions and percentage.
    private var modelRankTable: some View {
        let rows: [ModelRankRow] = (snapshot?.modelRankRows ?? [])
            .sorted(by: modelSort(key: modelSortKey, ascending: modelSortAsc))
        let maxTokens = rows.map(\.tokens).max() ?? 0
        let grand = snapshot?.inRangeTotalTokens ?? 0

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortHeader("模型", key: "name", current: modelSortKey, ascending: modelSortAsc, action: { toggleModelSort("name") })
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Agent").font(.system(size: Design.caption, weight: .semibold)).frame(width: 100, alignment: .leading)
                Text("份额").font(.system(size: Design.caption, weight: .semibold)).frame(width: 140, alignment: .leading)
                sortHeader("Tokens", key: "tokens", current: modelSortKey, ascending: modelSortAsc, width: 110, action: { toggleModelSort("tokens") })
                sortHeader("会话", key: "sessions", current: modelSortKey, ascending: modelSortAsc, width: 60, action: { toggleModelSort("sessions") })
                Text("占比").font(.system(size: Design.caption, weight: .semibold)).frame(width: 60, alignment: .trailing)
            }
            .padding(.vertical, 4)
            Divider()
            if rows.isEmpty {
                placeholder("所选范围内没有数据").padding(.vertical, 16)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        Text(row.name).font(.system(size: Design.caption)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.agents).font(.system(size: Design.caption)).foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.secondary.opacity(Design.slotAlpha))
                                RoundedRectangle(cornerRadius: Design.radiusS)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: maxTokens > 0 ? geo.size.width * CGFloat(row.tokens) / CGFloat(maxTokens) : 0)
                            }
                        }
                        .frame(width: 140, height: 12)
                        Text(intervalString(row.tokens)).font(.system(size: Design.caption, weight: .semibold))
                            .frame(width: 110, alignment: .trailing)
                        Text("\(row.sessions)").font(.system(size: Design.caption)).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Text("\(grand > 0 ? Int(Double(row.tokens) / Double(grand) * 100) : 0)%")
                            .font(.system(size: Design.caption)).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.5)
                }
            }
        }
    }

    // MARK: - Loading

    private func reload(force: Bool = false) {
        if force { scannedAgents = [] }
        // Agents already scanned count as loaded immediately — otherwise any
        // selection/range change clears the set and the "scanning" banner
        // spins forever over data that is already on screen.
        loadedAgents = Set(visibleAgents.filter { scannedAgents.contains($0) })
        // One all-time scan feeds the sidebar AND every range slice (records
        // carry timestamps; range windows filter in memory). Agents already
        // scanned this session keep their records — selection toggles don't
        // rescan the expensive sources (DSH zstd decompression).
        let missing = visibleAgents.filter { !scannedAgents.contains($0) }
        for agent in missing {
            Task.detached(priority: .userInitiated) {
                let agentRecords = service.collect(agent: agent, sinceMs: 0)
                await MainActor.run {
                    allRecords.removeAll { $0.agent == agent }
                    allRecords.append(contentsOf: agentRecords)
                    scannedAgents.insert(agent)
                    loadedAgents.insert(agent)
                    lastUpdated = Date()
                    updateSnapshot()
                }
            }
        }
        // Deselected agents drop out of the in-memory store immediately so
        // totals don't include them.
        let keep = Set(visibleAgents)
        allRecords.removeAll { !keep.contains($0.agent) }
        if missing.isEmpty { lastUpdated = Date() }
        updateSnapshot()
    }

    private func updateSnapshot() {
        let enabledRecords = allRecords.filter { enabledAgents.contains($0.agent) }
        let now = Date()
        let cal = Calendar.current

        // 1. Sidebar all-time stats
        let d7Tokens = enabledRecords.filter { $0.tsMs >= Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000) }.reduce(0) { $0 + $1.tokens }
        let d30Tokens = enabledRecords.filter { $0.tsMs >= Int64((now.timeIntervalSince1970 - 30 * 86400) * 1000) }.reduce(0) { $0 + $1.tokens }
        let activeDays = Set(enabledRecords.map { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.tsMs) / 1000)) })
        let activeDaysCount = activeDays.count
        let dailyAvgTokens = activeDaysCount > 0 ? enabledRecords.reduce(0) { $0 + $1.tokens } / activeDaysCount : 0
        let allSessionsCount = Set(enabledRecords.map { "\($0.agent):\($0.sessionId)" }).count

        let totalAll = enabledRecords.reduce(0) { $0 + $1.tokens }
        let topModels = mergedModelGroups(enabledRecords)
            .prefix(5).enumerated()
            .map { i, g in RankRow(idx: i + 1, name: g.name, tokens: g.tokens,
                                   share: totalAll > 0 ? Double(g.tokens) / Double(totalAll) * 100 : 0) }

        let firstTs = enabledRecords.map(\.tsMs).min()
        let dfDate = DateFormatter(); dfDate.dateFormat = "yyyy-MM-dd"
        let startedText = firstTs.map { dfDate.string(from: Date(timeIntervalSince1970: TimeInterval($0) / 1000)) } ?? "—"

        let maxWeeks = 26
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let daysToWeekEnd = (7 - weekday) % 7
        let gridEnd = cal.date(byAdding: .day, value: daysToWeekEnd, to: today) ?? today
        let gridStart = cal.date(byAdding: .day, value: -(maxWeeks * 7 - 1), to: gridEnd) ?? today

        var heatmapDaily: [Date: Int] = [:]
        for r in enabledRecords {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.tsMs) / 1000))
            heatmapDaily[day, default: 0] += r.tokens
        }
        let heatmapMaxDay = heatmapDaily.values.max() ?? 0

        var heatmapColumns: [[Date]] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            var week: [Date] = []
            for offset in 0..<7 {
                if let d = cal.date(byAdding: .day, value: offset, to: cursor) { week.append(d) }
            }
            heatmapColumns.append(week)
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? gridEnd
        }

        let trendStart = cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: now) ?? now)
        var trendDays: [Date] = []
        var tCursor = trendStart
        while tCursor <= now {
            trendDays.append(tCursor)
            tCursor = cal.date(byAdding: .day, value: 1, to: tCursor) ?? now
        }
        let trendValues = trendDays.map { heatmapDaily[$0] ?? 0 }
        let trendMax = trendValues.max() ?? 0

        // 2. In-range stats
        let rawInRange = inRange
        var agentTokens: [StatsAgent: Int] = [:]
        var agentModelCounts: [StatsAgent: Int] = [:]
        for agent in visibleAgents {
            let recs = rawInRange.filter { $0.agent == agent }
            agentTokens[agent] = recs.reduce(0) { $0 + $1.tokens }
            agentModelCounts[agent] = Set(recs.map { $0.model ?? "unknown" }).count
        }

        let current = rawInRange.filter { selectedAgentFilter == nil || $0.agent == selectedAgentFilter }
        let inRangeTotalTokens = current.reduce(0) { $0 + $1.tokens }
        let breakdown = current.filter(\.hasBreakdown)
        let freshInput = breakdown.reduce(0) { $0 + $1.freshInput }
        let cachedInput = breakdown.reduce(0) { $0 + $1.cached }
        let outputTokens = breakdown.reduce(0) { $0 + $1.output }
        let totalInput = freshInput + cachedInput
        let cacheHitRate: Double = totalInput > 0 ? Double(cachedInput) / Double(totalInput) * 100 : 0
        let hasCodexNotice = (selectedAgentFilter == nil || selectedAgentFilter == .codex) && !breakdown.isEmpty && breakdown.count < current.count

        let groupedDays = Dictionary(grouping: current) { rec -> String in
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(rec.tsMs) / 1000))
            return dfDate.string(from: day)
        }
        let dayRows: [DayRow] = groupedDays.map { date, recs in
            let b = recs.filter(\.hasBreakdown)
            return DayRow(
                id: date, date: date,
                total: recs.reduce(0) { $0 + $1.tokens },
                fresh: b.reduce(0) { $0 + $1.freshInput },
                cached: b.reduce(0) { $0 + $1.cached },
                output: b.reduce(0) { $0 + $1.output },
                sessions: Set(recs.map { "\($0.agent):\($0.sessionId)" }).count
            )
        }

        let groupedSessions = Dictionary(grouping: current) { rec in "\(rec.agent.rawValue)|\(rec.sessionId)" }
        let sessionRows: [SessionRow] = groupedSessions.map { _, recs in
            let first = recs[0]
            let title = first.title ?? "未命名会话（\(String(first.sessionId.prefix(8)))）"
            return SessionRow(
                id: "\(first.agent.rawValue)|\(first.sessionId)",
                title: title,
                agent: first.agent,
                tokens: recs.reduce(0) { $0 + $1.tokens },
                turns: recs.count
            )
        }

        let modelRankRows: [ModelRankRow] = mergedModelGroups(current).map { g in
            ModelRankRow(
                id: g.name.lowercased(),
                name: g.name,
                agents: g.agents.map(\.label).joined(separator: " / "),
                tokens: g.tokens,
                sessions: g.sessions
            )
        }

        snapshot = DashboardSnapshot(
            d7Tokens: d7Tokens,
            d30Tokens: d30Tokens,
            dailyAvgTokens: dailyAvgTokens,
            allSessionsCount: allSessionsCount,
            topModels: topModels,
            startedText: startedText,
            activeDaysCount: activeDaysCount,
            heatmapColumns: heatmapColumns,
            heatmapDaily: heatmapDaily,
            heatmapMaxDay: heatmapMaxDay,
            trendDays: trendDays,
            trendValues: trendValues,
            trendMax: trendMax,
            inRangeTotalTokens: inRangeTotalTokens,
            freshInput: freshInput,
            cachedInput: cachedInput,
            outputTokens: outputTokens,
            cacheHitRate: cacheHitRate,
            hasCodexNotice: hasCodexNotice,
            agentTokens: agentTokens,
            agentModelCounts: agentModelCounts,
            dayRows: dayRows,
            sessionRows: sessionRows,
            modelRankRows: modelRankRows
        )
    }

    // MARK: - Shared Pieces

    /// Cross-agent model grouping: key is the lowercased model name so
    /// case variants (glm-5.3-flash vs GLM-5.3-Flash) merge; the displayed
    /// name is the most frequent original casing. Unknown models stay
    /// per-agent buckets.
    private func mergedModelGroups(_ records: [UnifiedUsageRecord]) -> [(name: String, tokens: Int, sessions: Int, agents: [StatsAgent])] {
        struct Group {
            var tokens = 0
            var sessions = Set<String>()
            var agents = Set<StatsAgent>()
            var casings: [String: Int] = [:]
        }
        var groups: [String: Group] = [:]
        for r in records {
            let display = r.model ?? "未知（\(r.agent.label)）"
            let key = display.lowercased()
            var g = groups[key] ?? Group()
            g.tokens += r.tokens
            g.sessions.insert("\(r.agent):\(r.sessionId)")
            g.agents.insert(r.agent)
            g.casings[display, default: 0] += 1
            groups[key] = g
        }
        return groups
            .map { key, g in
                let name = g.casings.max { $0.value < $1.value }?.key ?? key
                return (name: name, tokens: g.tokens, sessions: g.sessions.count,
                        agents: g.agents.sorted { $0.rawValue < $1.rawValue })
            }
            .sorted { $0.tokens > $1.tokens }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: Design.caption)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}
