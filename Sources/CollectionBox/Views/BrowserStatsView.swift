import SwiftUI
import AppKit

public struct BrowserStatsView: View {
    @ObservedObject private var service: BrowserStatsService
    var onClose: () -> Void

    @State private var hoveredHour: Int? = nil
    @State private var copiedId: String? = nil
    @State private var isFrequentExpanded: Bool = true

    @MainActor
    public init(service: BrowserStatsService, onClose: @escaping () -> Void) {
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
                        sourceFilterBar(stats: stats)
                        overviewMetricsGrid(stats: stats)
                        hourlyRhythmCard(stats: stats)
                        topDomainsCard(stats: stats)
                        frequentPagesCard(stats: stats)
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
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("浏览统计")
                .font(.system(size: 14, weight: .bold))

            Spacer()

            HStack(spacing: 2) {
                ForEach(BrowserTimeRange.allCases) { r in
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

            PanelRefreshButton(isLoading: service.isLoading, helpText: "重新读取浏览器历史") {
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

    // MARK: - Source Filter Bar

    private func sourceFilterBar(stats: BrowserStatsData) -> some View {
        HStack(spacing: 6) {
            ForEach(BrowserSourceFilter.allCases) { filter in
                let isSelected = service.selectedSource == filter
                let countText: String = {
                    switch filter {
                    case .all: return "\(formatNumber(stats.diaVisits + stats.chromeVisits))"
                    case .dia: return "\(formatNumber(stats.diaVisits))"
                    case .chrome: return "\(formatNumber(stats.chromeVisits))"
                    }
                }()

                Button(action: {
                    Haptics.light()
                    service.selectedSource = filter
                }) {
                    HStack(spacing: 5) {
                        if filter == .dia {
                            Circle().fill(BrowserKind.dia.tintColor).frame(width: 6, height: 6)
                        } else if filter == .chrome {
                            Circle().fill(BrowserKind.chrome.tintColor).frame(width: 6, height: 6)
                        }
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        Text(countText)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusS)
                            .fill(isSelected ? Color.primary.opacity(0.10) : Color.primary.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Overview Grid

    private func overviewMetricsGrid(stats: BrowserStatsData) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            metricTile(
                icon: "safari.fill",
                title: "\(service.selectedRange.rawValue)访问",
                value: formatNumber(stats.rangeVisits),
                subtitle: "总访问存量: \(formatNumber(stats.totalVisits))",
                badgeText: service.selectedRange == .today ? "今日" : nil,
                badgeColor: .blue
            )

            metricTile(
                icon: "clock.fill",
                title: "有效停留",
                value: formatDuration(stats.rangeDurationSeconds),
                subtitle: "今日 \(formatDuration(stats.todayDurationSeconds)) · 单次封顶 30m",
                badgeText: stats.rangeDurationSeconds >= 3600 ? "深度" : nil,
                badgeColor: .purple
            )

            metricTile(
                icon: "sun.max.fill",
                title: "今日访问",
                value: "+\(formatNumber(stats.todayVisits))",
                subtitle: "日均访问 ~\(formatNumber(stats.avgDailyVisits)) 次",
                badgeText: stats.todayVisits > 80 ? "活跃" : nil,
                badgeColor: .orange
            )

            metricTile(
                icon: "network",
                title: "活跃站点",
                value: "\(formatNumber(stats.uniqueDomainsCount)) 站",
                subtitle: "Dia \(formatNumber(stats.diaVisits)) · Chrome \(formatNumber(stats.chromeVisits))",
                badgeText: nil,
                badgeColor: .teal
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

    // MARK: - 24-Hour Rhythm

    private func hourlyRhythmCard(stats: BrowserStatsData) -> some View {
        let maxCount = max(1, stats.hourlyStats.map(\.visitCount).max() ?? 1)
        let peakHour = stats.hourlyStats.max(by: { $0.visitCount < $1.visitCount })?.hour ?? 14

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("24 小时冲浪节律")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if let hovered = hoveredHour, let item = stats.hourlyStats.first(where: { $0.hour == hovered }) {
                    Text("\(hovered):00 - \(hovered):59 · \(item.visitCount) 次 · \(formatDuration(item.durationSeconds))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                } else {
                    Text("高峰时段: \(peakHour):00 前后")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(stats.hourlyStats) { h in
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                h.hour == hoveredHour
                                    ? Color.accentColor
                                    : (h.visitCount > maxCount / 2 ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.18))
                            )
                            .frame(height: max(3, CGFloat(h.visitCount) / CGFloat(maxCount) * 44))
                    }
                    .frame(maxWidth: .infinity, maxHeight: 44)
                    .contentShape(Rectangle())
                    .onHover { isHovered in
                        if isHovered { hoveredHour = h.hour } else if hoveredHour == h.hour { hoveredHour = nil }
                    }
                }
            }
            .frame(height: 48)

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

    // MARK: - Top Domains

    private func topDomainsCard(stats: BrowserStatsData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("站点访问排行")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("Top \(stats.topDomains.count) 域名")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if stats.topDomains.isEmpty {
                Text("当前时段暂无浏览记录")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(stats.topDomains) { item in
                        HStack(spacing: 8) {
                            domainIcon(for: item.domain, size: 16)

                            Text(item.domain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)

                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.06))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.75))
                                        .frame(width: max(4, g.size.width * CGFloat(item.percentage)))
                                }
                            }
                            .frame(height: 6)

                            Text("\(item.visitCount)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                                .frame(width: 38, alignment: .trailing)

                            Text(formatDuration(item.totalDurationSeconds))
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: Design.radiusM)
    }

    // MARK: - Frequent Pages

    private func frequentPagesCard(stats: BrowserStatsData) -> some View {
        let visiblePages = Array(
            stats.frequentPages
                .filter { !service.ignoredFrequentURLs.contains($0.url) }
                .prefix(8)
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("高频回访页面")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                if !service.ignoredFrequentURLs.isEmpty {
                    Button(action: {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            service.resetIgnoredFrequentPages()
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9, weight: .semibold))
                            Text("恢复 (\(service.ignoredFrequentURLs.count))")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("恢复已从榜单移除的页面")
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFrequentExpanded.toggle()
                    }
                }) {
                    Image(systemName: isFrequentExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isFrequentExpanded {
                if visiblePages.isEmpty {
                    Text("暂无高频回访页面")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(visiblePages) { page in
                            HStack(spacing: 8) {
                                domainIcon(for: page.domain, size: 15)

                                Button(action: {
                                    if let url = URL(string: page.url) {
                                        Haptics.light()
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(page.title)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                            .foregroundColor(.primary)

                                        HStack(spacing: 4) {
                                            Text(page.browser.rawValue)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(page.browser.tintColor)
                                            Text("· \(page.domain)")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .help("在浏览器中打开：\(page.url)")

                                // Copy URL button
                                Button(action: {
                                    copyToPasteboard(page.url, id: page.id)
                                }) {
                                    HStack(spacing: 3) {
                                        if copiedId == page.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.green)
                                            Text("已复制")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.green)
                                        } else {
                                            Text("\(page.visitCount)x")
                                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                                .foregroundColor(.accentColor)
                                            Image(systemName: "link")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                                .help("复制链接")

                                // Ignore button
                                Button(action: {
                                    Haptics.light()
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        service.ignoreFrequentPage(url: page.url)
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

    // MARK: - Subviews & Helpers

    @ViewBuilder
    private func domainIcon(for domain: String, size: CGFloat) -> some View {
        if let img = service.faviconImage(for: domain) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.85))
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func copyToPasteboard(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Haptics.light()
        copiedId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedId == id { copiedId = nil }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text("未检测到 Dia 或 Chrome 历史数据库")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)

                Text("支持免权限读取 ~/Library/Application Support 下的 Dia 与 Google Chrome 本地历史库。")
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
            ProgressView().scaleEffect(0.9)
            Text("正在读取 Dia / Chrome 浏览快照...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        let diaCount = service.detectedProfiles.filter { $0.browser == .dia }.count
        let chromeCount = service.detectedProfiles.filter { $0.browser == .chrome }.count
        let summaryParts = [
            diaCount > 0 ? "Dia (\(diaCount))" : nil,
            chromeCount > 0 ? "Chrome (\(chromeCount))" : nil
        ].compactMap { $0 }.joined(separator: " · ")

        return HStack {
            if !summaryParts.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("已挂载 \(summaryParts)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .help(service.detectedProfiles.map(\.historyPath).joined(separator: "\n"))
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

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60.0)
        if totalMinutes < 1 {
            return "\(Int(seconds))s"
        }
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }
}
