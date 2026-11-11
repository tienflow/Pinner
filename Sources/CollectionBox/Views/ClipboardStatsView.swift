import SwiftUI
import AppKit

public struct ClipboardStatsView: View {
    @ObservedObject private var service: ClipboardStatsService
    var onClose: () -> Void

    @State private var hoveredHour: Int? = nil
    @State private var copiedItemId: Int64? = nil
    @State private var isRepeatedExpanded: Bool = true

    @MainActor
    public init(service: ClipboardStatsService, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.15)

            if !service.isAvailable {
                emptyStateView
            } else if let stats = service.stats {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        // 1. Overview Metrics Grid
                        overviewMetricsGrid(stats: stats)

                        // 2. Content Type Distribution
                        typeDistributionCard(stats: stats)

                        // 3. 24-Hour Rhythm Heatmap
                        hourlyRhythmCard(stats: stats)

                        // 4. Top Source Applications
                        topAppsCard(stats: stats)

                        // 5. Top Repeated Assets (Reusable snippets)
                        repeatedAssetsCard(stats: stats)
                    }
                    .padding(16)
                }
            } else {
                loadingView
            }

            Divider().opacity(0.15)
            bottomBar
        }
        .frame(width: 460, height: 640)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("剪贴统计")
                .font(.system(size: 14, weight: .bold))

            Spacer()

            // Range capsule picker
            HStack(spacing: 2) {
                ForEach(ClipboardTimeRange.allCases) { r in
                    Button(action: {
                        Haptics.light()
                        service.selectedRange = r
                    }) {
                        Text(r.rawValue)
                            .font(.system(size: 11, weight: service.selectedRange == r ? .semibold : .regular))
                            .foregroundColor(service.selectedRange == r ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(service.selectedRange == r ? Color.primary.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))

            PanelRefreshButton(isLoading: service.isLoading, helpText: "重新统计数据") {
                service.refresh()
            }

            PanelCloseButton(helpText: "关闭面板 (⎋)") {
                Haptics.light()
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Overview Grid

    private func overviewMetricsGrid(stats: ClipboardStatsData) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            metricTile(
                icon: "doc.on.clipboard.fill",
                title: "\(service.selectedRange.rawValue)剪贴",
                value: "\(formatNumber(stats.rangeCount))",
                subtitle: "历史总存量: \(formatNumber(stats.totalCount))",
                badgeText: service.selectedRange == .today ? "今日" : nil,
                badgeColor: .blue
            )

            metricTile(
                icon: "sun.max.fill",
                title: "今日新增",
                value: "+\(formatNumber(stats.todayCount))",
                subtitle: "日均吞吐 ~\(formatNumber(stats.avgDailyCount)) 条",
                badgeText: stats.todayCount > 50 ? "活跃" : nil,
                badgeColor: .orange
            )
        }
    }

    private func metricTile(
        icon: String,
        title: String,
        value: String,
        subtitle: String,
        badgeText: String?,
        badgeColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(badgeColor)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(badgeColor.opacity(0.12)))
                }
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - Content Type Distribution

    private func typeDistributionCard(stats: ClipboardStatsData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内容形态分布")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(service.selectedRange.rawValue)合计 \(stats.rangeCount) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Stacked Bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(stats.typeStats) { t in
                        if t.percentage > 0.01 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(t.type.tintColor)
                                .frame(width: max(4, geo.size.width * CGFloat(t.percentage)))
                                .help("\(t.type.rawValue): \(t.count) 条 (\(Int(t.percentage * 100))%)")
                        }
                    }
                }
            }
            .frame(height: 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Legend Chips
            HStack(spacing: 12) {
                ForEach(stats.typeStats.prefix(4)) { t in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(t.type.tintColor)
                            .frame(width: 6, height: 6)

                        Text(t.type.rawValue)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text("\(t.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)

                        Text("(\(Int(t.percentage * 100))%)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - 24-Hour Rhythm Card

    private func hourlyRhythmCard(stats: ClipboardStatsData) -> some View {
        let maxCount = max(1, stats.hourlyStats.map(\.count).max() ?? 1)
        let peakHour = stats.hourlyStats.max(by: { $0.count < $1.count })?.hour ?? 14

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("24 小时工作节律")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if let hovered = hoveredHour, let item = stats.hourlyStats.first(where: { $0.hour == hovered }) {
                    Text("\(hovered):00 - \(hovered):59 · \(item.count) 次")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                } else {
                    Text("高产时段: \(peakHour):00 前后")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // 24 Bar Chart
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(stats.hourlyStats) { h in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                h.hour == hoveredHour
                                    ? Color.accentColor
                                    : (h.count > maxCount / 2 ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.18))
                            )
                            .frame(height: max(3, CGFloat(h.count) / CGFloat(maxCount) * 44))
                    }
                    .frame(maxWidth: .infinity, maxHeight: 44)
                    .contentShape(Rectangle())
                    .onHover { isHovered in
                        if isHovered { hoveredHour = h.hour } else if hoveredHour == h.hour { hoveredHour = nil }
                    }
                }
            }
            .frame(height: 48)

            // Hour labels (0, 6, 12, 18, 23)
            HStack {
                Text("0h").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("6h").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("12h").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("18h").font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Text("23h").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - Top Source Applications

    private func topAppsCard(stats: ClipboardStatsData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("来源应用画像")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("前 \(stats.topApps.count) 大应用")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(stats.topApps) { app in
                    let info = service.appInfo(for: app.bundleId)
                    HStack(spacing: 8) {
                        if let icon = info.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .frame(width: 18, height: 18)
                        }

                        Text(info.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)

                        // Progress bar
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.primary.opacity(0.06))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(4, g.size.width * CGFloat(app.percentage)))
                            }
                        }
                        .frame(height: 6)

                        Text("\(app.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .frame(width: 40, alignment: .trailing)

                        Text("\(Int(app.percentage * 100))%")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - Top Repeated Assets

    private func repeatedAssetsCard(stats: ClipboardStatsData) -> some View {
        let visibleItems = Array(
            stats.topRepeated
                .filter { !service.ignoredRepeatedIDs.contains($0.id) }
                .prefix(8)
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("高频复用资产")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                if !service.ignoredRepeatedIDs.isEmpty {
                    Button(action: {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            service.resetIgnoredRepeatedItems()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9, weight: .semibold))
                            Text("恢复 (\(service.ignoredRepeatedIDs.count))")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("恢复已从榜单移除的条目")
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRepeatedExpanded.toggle()
                    }
                }) {
                    Image(systemName: isRepeatedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isRepeatedExpanded {
                if visibleItems.isEmpty {
                    Text("暂无高频重复条目")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(visibleItems) { item in
                            let appInfo = item.appBundleId.map { service.appInfo(for: $0) }
                            HStack(spacing: 8) {
                                Image(systemName: item.type.icon)
                                    .font(.system(size: 11))
                                    .foregroundColor(item.type.tintColor)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundColor(.primary)

                                    if let name = appInfo?.name {
                                        Text("来自 \(name)")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer(minLength: 4)

                                // Copy badge & button
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.text, forType: .string)
                                    Haptics.light()
                                    copiedItemId = item.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        if copiedItemId == item.id { copiedItemId = nil }
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        if copiedItemId == item.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.green)
                                            Text("已复制")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.green)
                                        } else {
                                            Text("\(item.copyCount)x")
                                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                                .foregroundColor(.accentColor)
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                                .help("复制到剪贴板")

                                // Remove from leaderboard button
                                Button(action: {
                                    Haptics.light()
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        service.ignoreRepeatedItem(id: item.id)
                                    }
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.primary.opacity(0.05)))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("从榜单移除")
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Design.radiusS)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - Empty & Loading States

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text("未检测到本地 PasteNow 数据库")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text("本功能开箱适配 PasteNow 商业版的本地 CoreData SQLite 库。\n请确保已在当前 Mac 上安装并至少运行过一次 PasteNow。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button(action: {
                service.refresh()
            }) {
                Text("重新检测")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .scaleEffect(0.9)
            Text("正在读取剪贴板数据库...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if let dbPath = service.dbPath {
                let filename = (dbPath as NSString).lastPathComponent
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("已挂载 \(filename)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .help(dbPath)
            }

            Spacer()

            if let time = service.lastRefreshTime {
                Text("刷新于 \(formattedTime(time))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatNumber(_ num: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: num)) ?? "\(num)"
    }
}
