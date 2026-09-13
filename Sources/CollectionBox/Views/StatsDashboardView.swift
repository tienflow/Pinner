import SwiftUI

struct StatsDashboardView: View {
    enum DashRange: Int, CaseIterable, Identifiable {
        case today = 1, week = 7, month = 30, all = 0, custom = -1
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return "今天"
            case .week: return "近 7 天"
            case .month: return "近 30 天"
            case .all: return "全部"
            case .custom: return "自定义"
            }
        }
    }

    @State private var range: DashRange = .month
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var allRecords: [UnifiedUsageRecord] = []   // one full scan; all views slice in memory
    @State private var loadedAgents: Set<StatsAgent> = []
    @State private var lastUpdated: Date?
    @State private var detailTab: Int = 0
    private let service = StatsDashboardService.shared

    private let agentColor: [StatsAgent: Color] = [
        .codex: .purple, .gemini: .blue, .workbuddy: .green
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            mainArea
        }
        .frame(minWidth: 1040, idealWidth: 1120, minHeight: 680, idealHeight: 760)
        .onAppear { reload() }
        .onChange(of: range) { _, newRange in
            if newRange != .custom { reload() }
        }
        .onChange(of: customStart) { _, _ in if range == .custom { reload() } }
        .onChange(of: customEnd) { _, _ in if range == .custom { reload() } }
    }

    // MARK: - Range Window

    private var effectiveSinceMs: Int64 {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .today: return Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000)
        case .week: return Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000)
        case .month: return Int64((now.timeIntervalSince1970 - 30 * 86400) * 1000)
        case .all: return 0
        case .custom: return Int64(cal.startOfDay(for: customStart).timeIntervalSince1970 * 1000)
        }
    }

    private var effectiveUntilMs: Int64 {
        if range == .custom {
            return Int64((customEnd.timeIntervalSince1970 + 86400) * 1000) // inclusive end day
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private var inRange: [UnifiedUsageRecord] {
        allRecords.filter { $0.tsMs >= effectiveSinceMs && $0.tsMs <= effectiveUntilMs }
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
        let all = allRecords
        let now = Date()
        let cal = Calendar.current
        let d7 = all.filter { $0.tsMs >= Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000) }.reduce(0) { $0 + $1.tokens }
        let d30 = all.filter { $0.tsMs >= Int64((now.timeIntervalSince1970 - 30 * 86400) * 1000) }.reduce(0) { $0 + $1.tokens }
        let activeDays = Set(all.map { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.tsMs) / 1000)) }).count
        let dailyAvg = activeDays > 0 ? all.reduce(0) { $0 + $1.tokens } / activeDays : 0

        return HStack(spacing: 6) {
            miniStat(WorkBuddyStats.formatTokens(d7), "7天")
            miniStat(WorkBuddyStats.formatTokens(d30), "30天")
            miniStat(WorkBuddyStats.formatTokens(dailyAvg), "日均")
            miniStat("\(Set(all.map { "\($0.agent):\($0.sessionId)" }).count)", "会话")
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
        struct RankRow: Identifiable {
            let idx: Int; let name: String; let share: Double
            var id: Int { idx }
        }
        let grouped = Dictionary(grouping: allRecords) { $0.model ?? "未知（\($0.agent.label)）" }
        let total = allRecords.reduce(0) { $0 + $1.tokens }
        let rows = grouped
            .map { name, recs -> RankRow in
                let tokens = recs.reduce(0) { $0 + $1.tokens }
                return RankRow(idx: 0, name: name, share: total > 0 ? Double(tokens) / Double(total) * 100 : 0)
            }
            .sorted { $0.share > $1.share }
            .prefix(5).enumerated().map { i, r in RankRow(idx: i + 1, name: r.name, share: r.share) }

        return VStack(alignment: .leading, spacing: 7) {
            if rows.isEmpty {
                placeholder("正在扫描…")
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
                        Spacer()
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
        let cal = Calendar.current
        let first = allRecords.map(\.tsMs).min()
        let activeDays = Set(allRecords.map { cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.tsMs) / 1000)) }).count
        let started: String = first.map { ts in
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
        } ?? "—"
        return HStack {
            Text("起始 \(started)").font(.system(size: Design.micro)).foregroundStyle(.secondary)
            Spacer()
            Text("活跃 \(activeDays) 天").font(.system(size: Design.micro)).foregroundStyle(.secondary)
        }
    }

    /// Half-year contribution grid, Sun-first rows, green scale — all-time.
    private var sidebarHeatmapCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("活动热力图").font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(timeZoneLabel).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
            if allRecords.isEmpty {
                placeholder("正在扫描…")
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
        let cal = Calendar.current
        let maxWeeks = 26
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today)
        let daysToWeekEnd = (7 - weekday) % 7
        let gridEnd = cal.date(byAdding: .day, value: daysToWeekEnd, to: today)!
        let gridStart = cal.date(byAdding: .day, value: -(maxWeeks * 7 - 1), to: gridEnd)!

        var daily: [Date: Int] = [:]
        for r in allRecords {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.tsMs) / 1000))
            daily[day, default: 0] += r.tokens
        }
        let maxDay = daily.values.max() ?? 0

        var columns: [[Date]] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            var week: [Date] = []
            for offset in 0..<7 {
                if let d = cal.date(byAdding: .day, value: offset, to: cursor) { week.append(d) }
            }
            columns.append(week)
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? gridEnd
        }

        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "M/d"
        let monthFormatter = DateFormatter(); monthFormatter.dateFormat = "M月"
        let rowNames = ["日", "一", "二", "三", "四", "五", "六"]  // columns[ci][ri]: ri 0 = gridStart's weekday; gridStart is a Sunday by construction

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text("").frame(width: 16)
                ForEach(columns.indices, id: \.self) { ci in
                    VStack(spacing: 0) {
                        if ci == 0 || cal.component(.month, from: columns[ci][0]) != cal.component(.month, from: columns[ci - 1][0]) {
                            Text(monthFormatter.string(from: columns[ci][0]))
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 12, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { ri in
                        Text(rowNames[ri]).font(.system(size: 8)).foregroundStyle(.tertiary)
                            .frame(width: 16, height: 12, alignment: .trailing)
                    }
                }
                HStack(alignment: .top, spacing: 2) {
                    ForEach(columns.indices, id: \.self) { ci in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { ri in
                                let day = columns[ci][ri]
                                let tokens = daily[day] ?? 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(heatColor(tokens: tokens, maxDay: maxDay))
                                    .frame(width: 12, height: 12)
                                    .help(tokens > 0 ? "\(dayFormatter.string(from: day))：\(WorkBuddyStats.formatTokens(tokens)) tokens" : dayFormatter.string(from: day))
                            }
                        }
                    }
                }
            }
        }
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
        let cal = Calendar.current
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: Date())!)
        var daily: [Date: Int] = [:]
        for r in allRecords {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.tsMs) / 1000))
            daily[day, default: 0] += r.tokens
        }
        var days: [Date] = []
        var cursor = start
        while cursor <= Date() {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? Date()
        }
        let values = days.map { daily[$0] ?? 0 }
        let maxV = values.max() ?? 0
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        return VStack(alignment: .leading, spacing: 6) {
            Text("用量趋势").font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)
            if allRecords.isEmpty {
                placeholder("正在扫描…")
            } else {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(values.indices, id: \.self) { i in
                        let h: CGFloat = maxV > 0 ? CGFloat(CGFloat(values[i]) / CGFloat(maxV)) * 72 : 0
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.green.opacity(values[i] > 0 ? 0.85 : 0.15))
                            .frame(height: max(3, h))
                            .help("\(df.string(from: days[i]))：\(WorkBuddyStats.formatTokens(values[i])) tokens")
                    }
                }
                .frame(height: 74)
                HStack {
                    Text(df.string(from: days.first ?? start)).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(df.string(from: days.last ?? start)).font(.system(size: Design.micro)).foregroundStyle(.tertiary)
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
            if let last = lastUpdated {
                Text("刷新于 \(last, style: .time)").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
            Button(action: reload) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("刷新").accessibilityLabel("刷新")
        }
    }

    private var totalTokenHeader: some View {
        let current = inRange
        let total = current.reduce(0) { $0 + $1.tokens }
        let breakdown = current.filter(\.hasBreakdown)
        let fresh = breakdown.reduce(0) { $0 + $1.freshInput }
        let cached = breakdown.reduce(0) { $0 + $1.cached }
        let output = breakdown.reduce(0) { $0 + $1.output }
        let hitRate: Double = breakdown.reduce(0) { $0 + $1.freshInput + $1.cached } > 0
            ? Double(cached) / Double(breakdown.reduce(0) { $0 + $1.freshInput + $1.cached }) * 100 : 0

        return VStack(spacing: 8) {
            Text("TOKEN 总量").font(.system(size: Design.caption, weight: .medium)).foregroundStyle(.secondary)
                .tracking(2)
            Text(intervalString(total))
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.4)
            Text("新增输入 \(intervalString(fresh)) · 输出 \(intervalString(output)) · 缓存命中 \(String(format: "%.1f%%", hitRate))")
                .font(.system(size: Design.body, weight: .medium))
                .foregroundStyle(.green)
            if !breakdown.isEmpty && breakdown.count < current.count {
                Text("输入/输出/缓存明细不含 Codex（其数据源仅提供总量）")
                    .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
            if loadedAgents.count < StatsAgent.allCases.count {
                Text("正在扫描 \(StatsAgent.allCases.count - loadedAgents.count) 个 Agent…")
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
        let current = inRange
        let grand = current.reduce(0) { $0 + $1.tokens }
        return VStack(spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(StatsAgent.allCases, id: \.self) { agent in
                        let tokens = current.filter { $0.agent == agent }.reduce(0) { $0 + $1.tokens }
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
        let current = inRange
        let grand = current.reduce(0) { $0 + $1.tokens }
        return HStack(spacing: 10) {
            ForEach(StatsAgent.allCases, id: \.self) { agent in
                let tokens = current.filter { $0.agent == agent }.reduce(0) { $0 + $1.tokens }
                let models = Set(current.filter { $0.agent == agent }.map { $0.model ?? "unknown" }).count
                let share = grand > 0 ? Double(tokens) / Double(grand) * 100 : 0.0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: agent.symbolName).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(agentColor[agent] ?? .secondary)
                        Text(agent.label.uppercased())
                            .font(.system(size: Design.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !loadedAgents.contains(agent) { ProgressView().controlSize(.mini) }
                    }
                    Text(String(format: "%.1f%%", share))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(models) 模型")
                        .font(.system(size: Design.caption)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(Design.slotAlpha))
                .cornerRadius(Design.radiusM)
            }
        }
    }

    // MARK: - Detail Tabs

    private var detailTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("明细", selection: $detailTab) {
                Text("每日明细").tag(0)
                Text("会话排行").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            if detailTab == 0 { dailyBreakdownTable } else { sessionRankTable }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private var dailyBreakdownTable: some View {
        struct DayRow: Identifiable {
            let id: String
            let date: String
            let total: Int
            let fresh: Int
            let cached: Int
            let output: Int
            let sessions: Int
        }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: inRange) { rec -> String in
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(rec.tsMs) / 1000))
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return df.string(from: day)
        }
        let rows: [DayRow] = grouped.map { date, recs in
            let breakdown = recs.filter(\.hasBreakdown)
            return DayRow(
                id: date, date: date,
                total: recs.reduce(0) { $0 + $1.tokens },
                fresh: breakdown.reduce(0) { $0 + $1.freshInput },
                cached: breakdown.reduce(0) { $0 + $1.cached },
                output: breakdown.reduce(0) { $0 + $1.output },
                sessions: Set(recs.map { "\($0.agent):\($0.sessionId)" }).count
            )
        }
        .sorted { $0.date > $1.date }

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
                Text("净输入/输出/缓存列不含 Codex（数据源仅提供总量）")
                    .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("日期").font(.system(size: Design.caption, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            Text("合计").font(.system(size: Design.caption, weight: .semibold)).frame(width: 110, alignment: .trailing)
            Text("净输入").font(.system(size: Design.caption, weight: .semibold)).frame(width: 100, alignment: .trailing)
            Text("输出").font(.system(size: Design.caption, weight: .semibold)).frame(width: 100, alignment: .trailing)
            Text("缓存").font(.system(size: Design.caption, weight: .semibold)).frame(width: 120, alignment: .trailing)
            Text("会话").font(.system(size: Design.caption, weight: .semibold)).frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var sessionRankTable: some View {
        struct SessionRow: Identifiable {
            let id: String
            let title: String
            let agent: StatsAgent
            let tokens: Int
            let turns: Int
        }
        let grouped = Dictionary(grouping: inRange) { rec in "\(rec.agent.rawValue)|\(rec.sessionId)" }
        let rows: [SessionRow] = grouped.map { _, recs in
            let first = recs[0]
            let title = first.title ?? "未命名会话（\(String(first.sessionId.prefix(8)))）"
            return SessionRow(id: "\(first.agent.rawValue)|\(first.sessionId)", title: title,
                              agent: first.agent, tokens: recs.reduce(0) { $0 + $1.tokens },
                              turns: recs.count)
        }
        .sorted { $0.tokens > $1.tokens }
        .prefix(30)
        .map { $0 }

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("会话").font(.system(size: Design.caption, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text("Agent").font(.system(size: Design.caption, weight: .semibold)).frame(width: 90, alignment: .leading)
                Text("Tokens").font(.system(size: Design.caption, weight: .semibold)).frame(width: 110, alignment: .trailing)
                Text("轮次").font(.system(size: Design.caption, weight: .semibold)).frame(width: 60, alignment: .trailing)
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

    // MARK: - Loading

    private func reload() {
        loadedAgents = []
        // One all-time scan feeds the sidebar AND every range slice (records
        // carry timestamps; range windows filter in memory).
        for agent in StatsAgent.allCases {
            Task.detached(priority: .userInitiated) {
                let agentRecords = service.collect(agent: agent, sinceMs: 0)
                await MainActor.run {
                    allRecords.removeAll { $0.agent == agent }
                    allRecords.append(contentsOf: agentRecords)
                    loadedAgents.insert(agent)
                    lastUpdated = Date()
                }
            }
        }
    }

    // MARK: - Shared Pieces

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: Design.caption)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}
