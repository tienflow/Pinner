import SwiftUI

struct StatsDashboardView: View {
    enum DashRange: Int, CaseIterable, Identifiable {
        case d7 = 7, d30 = 30, d90 = 90, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .d7: return "近 7 天"
            case .d30: return "近 30 天"
            case .d90: return "近 90 天"
            case .all: return "全部"
            }
        }
        var daysBack: Int64 { Int64(rawValue) }
    }

    @State private var range: DashRange = .d30
    @State private var records: [UnifiedUsageRecord] = []
    @State private var loadedAgents: Set<StatsAgent> = []
    @State private var lastUpdated: Date?
    private let service = StatsDashboardService.shared

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overviewSection
                    agentSection
                    modelSection
                    heatmapSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .onAppear { reload() }
        .onChange(of: range) { _, _ in reload() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("时间范围", selection: $range) {
                ForEach(DashRange.allCases) { r in Text(r.label).tag(r) }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            Spacer()
            if let last = lastUpdated {
                Text("上次刷新 \(last, style: .time)").font(.system(size: Design.caption)).foregroundStyle(.tertiary)
            }
            Button(action: reload) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("刷新数据").accessibilityLabel("刷新数据")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Derived

    private var windowStartMs: Int64 {
        guard range.daysBack > 0 else { return 0 }
        return Int64((Date().timeIntervalSince1970 - Double(range.daysBack) * 86400) * 1000)
    }

    private var previousStartMs: Int64 {
        guard range.daysBack > 0 else { return 0 }
        return windowStartMs - range.daysBack * 86400 * 1000
    }

    private var currentRecords: [UnifiedUsageRecord] {
        records.filter { $0.tsMs >= windowStartMs }
    }

    private var previousTokens: Int {
        guard range.daysBack > 0 else { return 0 }
        let s = previousStartMs
        return records.filter { $0.tsMs >= s && $0.tsMs < windowStartMs }.reduce(0) { $0 + $1.tokens }
    }

    private func trend(_ current: Int, _ previous: Int) -> Double? {
        guard previous > 0 else { return nil }
        return Double(current - previous) / Double(previous) * 100
    }

    // MARK: - Overview

    private var overviewSection: some View {
        let total = currentRecords.reduce(0) { $0 + $1.tokens }
        let sessions = Set(currentRecords.map { "\($0.agent):\($0.sessionId)" }).count
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("总览")
            HStack(spacing: 8) {
                bigCard(value: WorkBuddyStats.formatTokens(total), label: "全部 Agent 合计",
                        trend: trend(total, previousTokens), loading: loadedAgents.isEmpty)
                ForEach(StatsAgent.allCases, id: \.self) { agent in
                    let agentRecords = currentRecords.filter { $0.agent == agent }
                    bigCard(value: WorkBuddyStats.formatTokens(agentRecords.reduce(0) { $0 + $1.tokens }),
                            label: agent.label,
                            trend: trend(agentRecords.reduce(0) { $0 + $1.tokens },
                                         previousWindowTokens(agent: agent)),
                            loading: !loadedAgents.contains(agent))
                }
            }
            Text("会话数 \(sessions) · 记录 \(currentRecords.count) 条")
                .font(.system(size: Design.caption)).foregroundStyle(.secondary)
        }
    }

    private func previousWindowTokens(agent: StatsAgent) -> Int {
        guard range.daysBack > 0 else { return 0 }
        let s = previousStartMs
        return records.filter { $0.agent == agent && $0.tsMs >= s && $0.tsMs < windowStartMs }.reduce(0) { $0 + $1.tokens }
    }

    private func bigCard(value: String, label: String, trend: Double?, loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: Design.caption)).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                if let t = trend { trendBadge(t) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private func trendBadge(_ value: Double) -> some View {
        let isUp = value > 0
        let isFlat = abs(value) < 0.1
        let color: Color = isFlat ? .secondary : (isUp ? .green : .red)
        let text = isFlat ? "-" : "\(isUp ? "↑" : "↓")\(String(format: "%.0f", abs(value)))%"
        return Text(text).font(.system(size: Design.caption, weight: .medium)).foregroundStyle(color)
    }

    // MARK: - By Agent

    private var agentSection: some View {
        let totals: [(agent: StatsAgent, tokens: Int)] = StatsAgent.allCases.map { agent in
            (agent, currentRecords.filter { $0.agent == agent }.reduce(0) { $0 + $1.tokens })
        }
        let maxTokens = totals.map(\.tokens).max() ?? 0
        let grand = totals.reduce(0) { $0 + $1.tokens }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按 Agent")
            if grand == 0 {
                placeholderText(loadedAgents.isEmpty ? "正在扫描各 Agent 本地数据…" : "所选范围内没有数据")
            } else {
                VStack(spacing: 6) {
                    ForEach(totals, id: \.agent) { item in
                        HStack(spacing: 10) {
                            Text(item.agent.label)
                                .font(.system(size: Design.body))
                                .frame(width: 90, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.secondary.opacity(Design.slotAlpha))
                                    RoundedRectangle(cornerRadius: Design.radiusS)
                                        .fill(Color.accentColor.opacity(0.75))
                                        .frame(width: maxTokens > 0 ? geo.size.width * CGFloat(item.tokens) / CGFloat(maxTokens) : 0)
                                }
                            }
                            .frame(height: 16)
                            Text("\(WorkBuddyStats.formatTokens(item.tokens))  (\(grand > 0 ? Int(Double(item.tokens) / Double(grand) * 100) : 0)%)")
                                .font(.system(size: Design.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - By Model

    private var modelSection: some View {
        struct ModelRow: Identifiable {
            let id: String
            let agent: StatsAgent
            let model: String?
            let tokens: Int
            let sessions: Int
            var displayName: String { model ?? "未知（\(agent.label)）" }
        }
        let grouped = Dictionary(grouping: currentRecords) { rec in "\(rec.agent.rawValue)|\(rec.model ?? "")" }
        let rows: [ModelRow] = grouped.map { key, recs in
            let agent = recs[0].agent
            let model = recs[0].model
            return ModelRow(id: key, agent: agent, model: model,
                            tokens: recs.reduce(0) { $0 + $1.tokens },
                            sessions: Set(recs.map(\.sessionId)).count)
        }
        .sorted { $0.tokens > $1.tokens }
        let maxTokens = rows.first?.tokens ?? 0
        let grand = rows.reduce(0) { $0 + $1.tokens }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("按模型")
            if rows.isEmpty {
                placeholderText(loadedAgents.count < StatsAgent.allCases.count ? "正在扫描…" : "所选范围内没有数据")
            } else {
                VStack(spacing: 4) {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.agent.label)
                                .font(.system(size: Design.micro, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(Design.slotAlpha), in: Capsule())
                                .foregroundStyle(.secondary)
                                .frame(width: 74, alignment: .leading)
                            Text(row.displayName)
                                .font(.system(size: Design.body))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 190, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: Design.radiusS).fill(Color.secondary.opacity(Design.slotAlpha))
                                    RoundedRectangle(cornerRadius: Design.radiusS)
                                        .fill(Color.accentColor.opacity(0.75))
                                        .frame(width: maxTokens > 0 ? geo.size.width * CGFloat(row.tokens) / CGFloat(maxTokens) : 0)
                                }
                            }
                            .frame(height: 14)
                            Text("\(WorkBuddyStats.formatTokens(row.tokens)) · \(row.sessions) 会话 · \(grand > 0 ? Int(Double(row.tokens) / Double(grand) * 100) : 0)%")
                                .font(.system(size: Design.caption))
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .trailing)
                        }
                    }
                }
                Text("Gemini 的本地数据不含模型名，统一计入「未知」桶")
                    .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Heatmap (GitHub-style contribution grid)

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("热力图")
            if currentRecords.isEmpty {
                placeholderText(loadedAgents.count < StatsAgent.allCases.count ? "正在扫描…" : "所选范围内没有数据")
            } else {
                heatmapGrid
                legend
            }
        }
    }

    /// Up to 26 week-columns (oldest left), Mon..Sun rows, accent intensity by
    /// daily tokens relative to the busiest day in the span.
    private var heatmapGrid: some View {
        let cal = Calendar.current
        let maxWeeks = 26
        let spanDays = range.daysBack > 0 ? range.daysBack : Int64(maxWeeks * 7)
        let spanWeeks = Int(min(spanDays / 7, Int64(maxWeeks)))
        let today = cal.startOfDay(for: Date())
        // End the grid on the current week's Sunday so columns are full weeks.
        let weekday = cal.component(.weekday, from: today)          // 1=Sun..7=Sat
        let daysToWeekEnd = (7 - weekday) % 7                        // days until Sunday
        let gridEnd = cal.date(byAdding: .day, value: daysToWeekEnd, to: today)!
        let gridStart = cal.date(byAdding: .day, value: -(spanWeeks * 7 - 1), to: gridEnd)!

        var daily: [Date: Int] = [:]
        for r in currentRecords where r.tsMs >= Int64(gridStart.timeIntervalSince1970) * 1000 {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(r.tsMs) / 1000))
            daily[day, default: 0] += r.tokens
        }
        let maxDay = daily.values.max() ?? 0

        // Columns of 7 days, Monday-first rows.
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

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "M/d"
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "M月"

        return VStack(alignment: .leading, spacing: 4) {
            // Month labels
            HStack(spacing: 2) {
                ForEach(columns.indices, id: \.self) { ci in
                    VStack(spacing: 0) {
                        if ci == 0 || cal.component(.month, from: columns[ci][0]) != cal.component(.month, from: columns[max(0, ci - 1)][0]) {
                            Text(monthFormatter.string(from: columns[ci][0]))
                                .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 14, alignment: .leading)
                }
            }
            // Grid: 7 rows × N columns
            HStack(alignment: .top, spacing: 2) {
                ForEach(columns.indices, id: \.self) { ci in
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { ri in
                            let day = columns[ci][ri]
                            let tokens = daily[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cellColor(tokens: tokens, maxDay: maxDay))
                                .frame(width: 14, height: 14)
                                .help(tokens > 0
                                      ? "\(dayFormatter.string(from: day))：\(WorkBuddyStats.formatTokens(tokens)) tokens"
                                      : dayFormatter.string(from: day))
                        }
                    }
                }
            }
            Text("\(dayFormatter.string(from: gridStart)) – \(dayFormatter.string(from: min(gridEnd, today)))，按天聚合三个 Agent 的 token 总量")
                .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
        }
    }

    private func cellColor(tokens: Int, maxDay: Int) -> Color {
        guard tokens > 0, maxDay > 0 else { return Color.secondary.opacity(0.08) }
        let ratio = Double(tokens) / Double(maxDay)
        switch ratio {
        case ..<0.25: return Color.accentColor.opacity(0.25)
        case ..<0.5: return Color.accentColor.opacity(0.45)
        case ..<0.75: return Color.accentColor.opacity(0.65)
        default: return Color.accentColor.opacity(0.9)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("少").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
            ForEach([0.08, 0.25, 0.45, 0.65, 0.9], id: \.self) { alpha in
                RoundedRectangle(cornerRadius: 2).fill(alpha == 0.08 ? Color.secondary.opacity(alpha) : Color.accentColor.opacity(alpha))
                    .frame(width: 10, height: 10)
            }
            Text("多").font(.system(size: Design.micro)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Shared Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: Design.ui, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text).font(.system(size: Design.body)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    // MARK: - Loading

    private func reload() {
        let sinceMs = range == .all ? Int64(0) : windowStartMs
        records = []
        loadedAgents = []
        let agents = StatsAgent.allCases
        for agent in agents {
            Task.detached(priority: .userInitiated) {
                let agentRecords = service.collect(agent: agent, sinceMs: sinceMs)
                await MainActor.run {
                    // Drop this agent's stale rows, keep any others already in.
                    records.removeAll { $0.agent == agent }
                    records.append(contentsOf: agentRecords)
                    loadedAgents.insert(agent)
                    lastUpdated = Date()
                }
            }
        }
    }
}
