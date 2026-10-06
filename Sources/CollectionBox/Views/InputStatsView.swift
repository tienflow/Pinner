import SwiftUI
import AppKit

public struct InputStatsView: View {
    @ObservedObject private var service: InputStatsService
    var onClose: () -> Void

    @State private var isHourlyExpanded: Bool = true
    @State private var hoveredHour: Int? = nil
    @State private var showResetConfirm: Bool = false

    // Key Distribution (按键分布)
    private enum KeyFilterType: String, CaseIterable, Identifiable {
        case all = "全部"
        case shortcuts = "快捷键 ⌘"
        case regular = "单键"
        var id: String { rawValue }
    }
    @State private var isKeyDistributionExpanded: Bool = true
    @State private var selectedKeyFilter: KeyFilterType = .all
    @State private var isKeyDistributionShowMore: Bool = false

    // Historical Trend State
    @State private var selectedRange: InputHistoryRange = .days7
    @State private var selectedMetric: InputMetricType = .keyboard
    @State private var selectedChartType: InputChartType = .line
    @State private var hoveredDayIndex: Int? = nil
    @State private var isHistoryExpanded: Bool = true

    // App Statistics (按应用统计)
    @State private var selectedAppRange: AppStatsRange = .today
    @State private var selectedAppSortMetric: AppSortMetric = .keys
    @State private var selectedAppSortAscending: Bool = false
    @State private var isAppStatsExpanded: Bool = true

    @MainActor
    public init(service: InputStatsService, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.15)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    if !service.hasAccessibilityPermission {
                        permissionBanner
                    }

                    // 1. 2x2 Core Metrics Grid (Today: 键盘, 鼠标点击[含中键], 鼠标移动, 页面滚动)
                    metricsGrid

                    // 2. 24-Hour Hourly Flow Rhythm (Today)
                    hourlyFlowCard

                    // 3. 按键分布 / 高频按键统计 (按照 KeyStats，放在历史趋势上面)
                    keyDistributionCard

                    // 4. 7-Day / 30-Day Historical Trend (历史趋势)
                    historyTrendCard

                    // 5. 按应用统计 (按照截图，放在最下面，支持按时间筛选与多列条形图)
                    appStatsCard
                }
                .padding(14)
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
            Image(systemName: "keyboard.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("键鼠统计")
                .font(.system(size: 14, weight: .bold))

            // Status Indicator Dot
            HStack(spacing: 4) {
                Circle()
                    .fill(service.hasAccessibilityPermission && service.isMonitoring ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)

                Text(service.hasAccessibilityPermission ? (service.isMonitoring ? "监控中" : "未启动") : "需授权")
                    .font(.system(size: Design.micro, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(service.hasAccessibilityPermission ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
            )

            Spacer()

            // Close button
            Button {
                Haptics.light()
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭面板 (⎋)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("需要辅助功能权限")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Text("macOS 要求辅助功能权限以统计全局按键与鼠标点击事件")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("去授权") {
                Haptics.light()
                service.requestAccessibility()
                service.openAccessibilityPreferences()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Core Metrics Grid (2x2)

    private var metricsGrid: some View {
        let stats = service.stats
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            // Card 1: 键盘敲击
            metricCard(
                title: "键盘敲击",
                icon: "keyboard",
                value: DailyInputStats.formatNumber(stats.keyCount),
                subtitle: String(format: "瞬时 %.1f · 峰值 %.1f KPS", service.currentKPS, stats.peakKPS),
                badgeText: service.currentKPS > 0 ? "活跃" : nil,
                badgeColor: .blue
            )

            // Card 2: 鼠标点击
            let clickSubtitle = "左 \(stats.leftClickCount) · 右 \(stats.rightClickCount) · 中 \(stats.middleClickCount)\(stats.otherClickCount > 0 ? " · 侧 \(stats.otherClickCount)" : "")"
            metricCard(
                title: "鼠标点击",
                icon: "cursorarrow.rays",
                value: DailyInputStats.formatNumber(stats.totalClicks),
                subtitle: clickSubtitle,
                badgeText: String(format: "%.1f CPS", service.currentCPS),
                badgeColor: .indigo
            )

            // Card 3: 鼠标滑行
            metricCard(
                title: "鼠标移动",
                icon: "computermouse.fill",
                value: DailyInputStats.formatDistance(stats.mouseDistanceMeters),
                subtitle: "累计滑行物理位移",
                badgeText: nil,
                badgeColor: .teal
            )

            // Card 4: 页面滚动
            metricCard(
                title: "页面滚动",
                icon: "arrow.up.and.down",
                value: DailyInputStats.formatScrollPixels(stats.scrollDistancePixels),
                subtitle: "累计滚轮滚动像素",
                badgeText: nil,
                badgeColor: .purple
            )
        }
    }

    private func metricCard(
        title: String,
        icon: String,
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
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    // MARK: - 24-Hour Hourly Flow Rhythm

    private var hourlyFlowCard: some View {
        let buckets = service.stats.hourlyBuckets
        let maxActivity = buckets.map { $0.keyCount + $0.clickCount }.max() ?? 0
        let peakBucket = buckets.max(by: { ($0.keyCount + $0.clickCount) < ($1.keyCount + $1.clickCount) })
        let peakTotal = (peakBucket?.keyCount ?? 0) + (peakBucket?.clickCount ?? 0)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHourlyExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)

                        Text("24 小时心流节律")
                            .font(.system(size: Design.ui, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let peak = peakBucket, peakTotal > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text(String(format: "高峰：%02d:00 (%@)", peak.hour, DailyInputStats.formatNumber(peakTotal)))
                            .font(.system(size: Design.micro, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                }

                Spacer()

                if let h = hoveredHour, h < buckets.count {
                    let b = buckets[h]
                    Text(String(format: "%02d:00 · %d 击 / %d 点", h, b.keyCount, b.clickCount))
                        .font(.system(size: Design.micro, weight: .medium))
                        .foregroundColor(.primary)
                }

                cardCollapseButton(isExpanded: $isHourlyExpanded)
            }

            if isHourlyExpanded {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let spacing: CGFloat = 3
                        let totalSpacing = CGFloat(23) * spacing
                        let barWidth = max(4, (geo.size.width - totalSpacing) / 24)
                        let chartHeight: CGFloat = 46

                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(buckets) { b in
                                let total = b.keyCount + b.clickCount
                                let ratio: CGFloat = maxActivity > 0 ? (CGFloat(total) / CGFloat(maxActivity)) : 0.0
                                let rawH: CGFloat = ratio * chartHeight
                                let barH: CGFloat = total > 0 ? max(4.0, rawH) : 2.0
                                let isHovered = hoveredHour == b.hour

                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(
                                        total > 0
                                            ? (isHovered ? Color.accentColor : Color.accentColor.opacity(0.75))
                                            : Color.secondary.opacity(0.10)
                                    )
                                    .frame(width: barWidth, height: barH)
                                    .onHover { over in
                                        hoveredHour = over ? b.hour : nil
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: 48)

                    // Timeline X labels
                    HStack {
                        Text("00:00").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("06:00").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("12:00").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("18:00").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("23:59").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Key Distribution (按键分布 - 放在历史趋势上面)

    private var keyDistributionCard: some View {
        let allKeys = service.stats.keyFrequencies.sorted { $0.value > $1.value }
        let shortcutKeys = allKeys.filter { isShortcutKey($0.key) }
        let regularKeys = allKeys.filter { !isShortcutKey($0.key) }

        let displayedKeys: [(key: String, value: Int)] = {
            switch selectedKeyFilter {
            case .all: return allKeys
            case .shortcuts: return shortcutKeys
            case .regular: return regularKeys
            }
        }()

        let limit = isKeyDistributionShowMore ? displayedKeys.count : 18
        let itemsToShow = displayedKeys.prefix(limit)

        return VStack(alignment: .leading, spacing: 8) {
            // Header Row
            HStack(spacing: 6) {
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isKeyDistributionExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)

                        Text("按键分布")
                            .font(.system(size: Design.ui, weight: .semibold))
                            .foregroundColor(.secondary)

                        if !allKeys.isEmpty {
                            Text("\(allKeys.count) 种 · \(shortcutKeys.count) 组快捷键")
                                .font(.system(size: Design.micro))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                cardCollapseButton(isExpanded: $isKeyDistributionExpanded)
            }

            if isKeyDistributionExpanded {
                // Filter pills: [全部 | 快捷键 ⌘ | 单键]
                HStack(spacing: 4) {
                    ForEach(KeyFilterType.allCases) { f in
                        let isSelected = selectedKeyFilter == f
                        let count: Int = {
                            switch f {
                            case .all: return allKeys.count
                            case .shortcuts: return shortcutKeys.count
                            case .regular: return regularKeys.count
                            }
                        }()
                        Button {
                            Haptics.light()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedKeyFilter = f
                                isKeyDistributionShowMore = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(f.rawValue)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .opacity(isSelected ? 1.0 : 0.6)
                            }
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(2)
                .background(Capsule().fill(Color.secondary.opacity(0.06)))

                if displayedKeys.isEmpty {
                    Text(selectedKeyFilter == .shortcuts ? "暂无快捷键记录（如 ⌘C、⌘V、⌥A 等）" : "暂无按键记录")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 5) {
                        ForEach(itemsToShow, id: \.key) { item in
                            let isShortcut = isShortcutKey(item.key)
                            HStack(spacing: 4) {
                                Text(item.key)
                                    .font(.system(size: 10, weight: isShortcut ? .bold : .semibold, design: .monospaced))
                                    .foregroundColor(isShortcut ? .accentColor : .primary)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(item.value)")
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Design.radiusS)
                                    .fill(isShortcut ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.45))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Design.radiusS)
                                            .stroke(isShortcut ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 0.5)
                                    )
                            )
                        }
                    }

                    if displayedKeys.count > 18 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isKeyDistributionShowMore.toggle()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(isKeyDistributionShowMore ? "收起" : "展开全部 (\(displayedKeys.count))")
                                    .font(.system(size: 10, weight: .medium))
                                Image(systemName: isKeyDistributionShowMore ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Historical Trend Card (7-Day / 30-Day, Line / Bar)

    private var historyTrendCard: some View {
        let series = service.historySeries(days: selectedRange.rawValue)
        let values: [Double] = series.map { selectedMetric.value(from: $0) }
        let total: Double = values.reduce(0.0, +)
        let avg: Double = values.isEmpty ? 0.0 : total / Double(values.count)
        let maxVal: Double = values.max() ?? 0.0
        let safeMax: Double = maxVal > 0 ? maxVal : 1.0

        return VStack(alignment: .leading, spacing: 10) {
            // Header: Title + Range Pills + Chart Type Toggle + Expand Button
            HStack(spacing: 6) {
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHistoryExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)

                        Text("历史趋势")
                            .font(.system(size: Design.ui, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                // Range pills: 7天 / 30天
                HStack(spacing: 2) {
                    ForEach(InputHistoryRange.allCases) { r in
                        let isSelected = selectedRange == r
                        Button {
                            Haptics.light()
                            selectedRange = r
                            hoveredDayIndex = nil
                        } label: {
                            Text(r.label)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))

                // Chart type pills: 折线 / 柱状
                HStack(spacing: 2) {
                    chartTypeButton(type: .line, icon: "chart.xyaxis.line")
                    chartTypeButton(type: .bar, icon: "chart.bar.fill")
                }
                .padding(2)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))

                cardCollapseButton(isExpanded: $isHistoryExpanded)
            }

            if isHistoryExpanded {
                // Metric Selector Pills: [键盘 | 点击 | 移动 | 滚动]
                HStack(spacing: 6) {
                    ForEach(InputMetricType.allCases) { m in
                        let isSelected = selectedMetric == m
                        Button {
                            Haptics.light()
                            selectedMetric = m
                            hoveredDayIndex = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: m.icon)
                                    .font(.system(size: 9))
                                Text(m.rawValue)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            }
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: Design.radiusS)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Summary Numbers Banner
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Text("总计:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(selectedMetric.formatTotal(total))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 3) {
                        Text("日均:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(selectedMetric.formatValue(avg))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let idx = hoveredDayIndex, idx >= 0, idx < series.count {
                        let item = series[idx]
                        let itemVal = values[idx]
                        HStack(spacing: 4) {
                            Text(item.shortDateLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(selectedMetric.formatValue(itemVal))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    }
                }
                .padding(.horizontal, 2)

                // Chart Drawing
                if selectedChartType == .bar {
                    barChartView(series: series, values: values, safeMax: safeMax)
                } else {
                    lineChartView(series: series, values: values, safeMax: safeMax)
                }

                // X-Axis Date Labels
                xAxisLabels(series: series)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func chartTypeButton(type: InputChartType, icon: String) -> some View {
        let isSelected = selectedChartType == type
        return Button {
            Haptics.light()
            selectedChartType = type
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func barChartView(series: [DailyInputSummary], values: [Double], safeMax: Double) -> some View {
        let count = series.count
        let chartHeight: CGFloat = 80

        return GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let spacing: CGFloat = count > 14 ? 2.0 : 4.0
            let totalSpacing: CGFloat = spacing * CGFloat(count - 1)
            let barWidth: CGFloat = max(3.0, (w - totalSpacing) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { idx in
                    let val = values[idx]
                    let ratio: CGFloat = CGFloat(val / safeMax)
                    let rawH: CGFloat = ratio * chartHeight
                    let barH: CGFloat = val > 0 ? max(4.0, rawH) : 2.0
                    let isHovered = hoveredDayIndex == idx

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            val > 0
                                ? (isHovered ? Color.accentColor : Color.accentColor.opacity(0.75))
                                : Color.secondary.opacity(0.10)
                        )
                        .frame(width: barWidth, height: barH)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isHovered ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                        .onHover { over in
                            hoveredDayIndex = over ? idx : nil
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 80)
    }

    private func lineChartView(series: [DailyInputSummary], values: [Double], safeMax: Double) -> some View {
        let count = series.count

        return GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let h: CGFloat = geo.size.height
            let padX: CGFloat = 8
            let padY: CGFloat = 8
            let innerW: CGFloat = max(1, w - padX * 2)
            let innerH: CGFloat = max(1, h - padY * 2)

            let points: [CGPoint] = (0..<count).map { idx in
                let val = values[idx]
                let x: CGFloat = count > 1 ? padX + (CGFloat(idx) / CGFloat(count - 1)) * innerW : padX + innerW / 2
                let ratio: CGFloat = CGFloat(val / safeMax)
                let y: CGFloat = padY + (1.0 - ratio) * innerH
                return CGPoint(x: x, y: y)
            }

            ZStack(alignment: .topLeading) {
                // Background baseline
                Path { path in
                    path.move(to: CGPoint(x: padX, y: h - padY))
                    path.addLine(to: CGPoint(x: w - padX, y: h - padY))
                }
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)

                if points.count >= 2 {
                    // Area Gradient Fill
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: h - padY))
                        path.addLine(to: points[0])
                        for pt in points.dropFirst() {
                            path.addLine(to: pt)
                        }
                        if let last = points.last {
                            path.addLine(to: CGPoint(x: last.x, y: h - padY))
                        }
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Line Stroke
                    Path { path in
                        path.move(to: points[0])
                        for pt in points.dropFirst() {
                            path.addLine(to: pt)
                        }
                    }
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }

                // Points for 7-day view or hover
                if count <= 14 {
                    ForEach(0..<count, id: \.self) { idx in
                        let pt = points[idx]
                        let isHovered = hoveredDayIndex == idx
                        let val = values[idx]
                        if val > 0 || isHovered {
                            Circle()
                                .fill(isHovered ? Color.white : Color.accentColor)
                                .frame(width: isHovered ? 7 : 4, height: isHovered ? 7 : 4)
                                .overlay(
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: isHovered ? 2 : 0)
                                )
                                .position(pt)
                        }
                    }
                }

                // Hover indicator line & dot
                if let idx = hoveredDayIndex, idx < points.count {
                    let pt = points[idx]
                    Path { path in
                        path.move(to: CGPoint(x: pt.x, y: padY))
                        path.addLine(to: CGPoint(x: pt.x, y: h - padY))
                    }
                    .stroke(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2.5))
                        .position(pt)
                }

                // Invisible hover tracking slices across width
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { idx in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onHover { over in
                                if over {
                                    hoveredDayIndex = idx
                                } else if hoveredDayIndex == idx {
                                    hoveredDayIndex = nil
                                }
                            }
                    }
                }
            }
        }
        .frame(height: 80)
    }

    private func xAxisLabels(series: [DailyInputSummary]) -> some View {
        let count = series.count
        return HStack {
            if count <= 7 {
                ForEach(0..<count, id: \.self) { idx in
                    Text(series[idx].shortDateLabel)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            } else {
                let i0 = 0
                let i1 = count / 4
                let i2 = count / 2
                let i3 = (count * 3) / 4
                let i4 = count - 1
                Text(series[i0].shortDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(series[i1].shortDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(series[i2].shortDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(series[i3].shortDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(series[i4].shortDateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - App Statistics (按应用统计 - 放在最下面)

    private var appStatsCard: some View {
        let apps = service.aggregatedAppStats(range: selectedAppRange).sorted { a, b in
            if selectedAppSortAscending {
                switch selectedAppSortMetric {
                case .app:
                    return a.appName.localizedStandardCompare(b.appName) == .orderedAscending
                case .keys:
                    if a.keyCount != b.keyCount { return a.keyCount < b.keyCount }
                    return a.clickCount < b.clickCount
                case .clicks:
                    if a.clickCount != b.clickCount { return a.clickCount < b.clickCount }
                    return a.keyCount < b.keyCount
                case .scroll:
                    if a.scrollDistancePixels != b.scrollDistancePixels { return a.scrollDistancePixels < b.scrollDistancePixels }
                    return a.clickCount < b.clickCount
                }
            } else {
                switch selectedAppSortMetric {
                case .app:
                    return a.appName.localizedStandardCompare(b.appName) == .orderedDescending
                case .keys:
                    if a.keyCount != b.keyCount { return a.keyCount > b.keyCount }
                    return a.clickCount > b.clickCount
                case .clicks:
                    if a.clickCount != b.clickCount { return a.clickCount > b.clickCount }
                    return a.keyCount > b.keyCount
                case .scroll:
                    if a.scrollDistancePixels != b.scrollDistancePixels { return a.scrollDistancePixels > b.scrollDistancePixels }
                    return a.clickCount > b.clickCount
                }
            }
        }
        let totalKeys = apps.reduce(0) { $0 + $1.keyCount }
        let totalClicks = apps.reduce(0) { $0 + $1.clickCount }
        let totalScroll = apps.reduce(0.0) { $0 + $1.scrollDistancePixels }

        let maxKeys = apps.map { $0.keyCount }.max() ?? 1
        let maxClicks = apps.map { $0.clickCount }.max() ?? 1
        let maxScroll = apps.map { $0.scrollDistancePixels }.max() ?? 1.0

        return VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAppStatsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("按应用统计")
                                .font(.system(size: Design.ui, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("按应用统计键盘/点击/滚动，仅保存聚合数据")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                cardCollapseButton(isExpanded: $isAppStatsExpanded)
            }

            if isAppStatsExpanded {
                // Range pills: [今天 | 过去7天 | 过去30天 | 全部]
                HStack(spacing: 4) {
                    ForEach(AppStatsRange.allCases) { r in
                        let isSelected = selectedAppRange == r
                        Button {
                            Haptics.light()
                            selectedAppRange = r
                        } label: {
                            Text(r.rawValue)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(2)
                .background(Capsule().fill(Color.secondary.opacity(0.06)))

                // Summary Numbers Banner
                HStack(spacing: 6) {
                    Text("总计:")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text("\(DailyInputStats.formatNumber(totalKeys)) 键击")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.blue)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text("\(DailyInputStats.formatNumber(totalClicks)) 点击")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.green)

                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text("\(DailyInputStats.formatScrollPixels(totalScroll)) 滚动")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.orange)

                    Spacer()
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

                // Table Column Header (Sortable)
                HStack(spacing: 6) {
                    appColumnHeaderButton

                    appSortHeaderButton(title: "键盘", metric: .keys, color: .blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    appSortHeaderButton(title: "点击", metric: .clicks, color: .green)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    appSortHeaderButton(title: "滚动", metric: .scroll, color: .orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                Divider().opacity(0.1)

                // App Rows
                if apps.isEmpty {
                    Text("暂无应用活动记录")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 6) {
                        ForEach(apps.prefix(12)) { app in
                            HStack(spacing: 6) {
                                // App identity
                                HStack(spacing: 5) {
                                    AppIconImage(bundleId: app.bundleId)
                                    Text(app.appName)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                                .frame(width: 95, alignment: .leading)

                                // Key bar (Blue)
                                appMetricBar(
                                    valueText: DailyInputStats.formatNumber(app.keyCount),
                                    ratio: maxKeys > 0 ? CGFloat(app.keyCount) / CGFloat(maxKeys) : 0,
                                    color: .blue
                                )
                                .frame(maxWidth: .infinity)

                                // Click bar (Green)
                                appMetricBar(
                                    valueText: DailyInputStats.formatNumber(app.clickCount),
                                    ratio: maxClicks > 0 ? CGFloat(app.clickCount) / CGFloat(maxClicks) : 0,
                                    color: .green
                                )
                                .frame(maxWidth: .infinity)

                                // Scroll bar (Orange)
                                appMetricBar(
                                    valueText: DailyInputStats.formatScrollPixels(app.scrollDistancePixels),
                                    ratio: maxScroll > 0 ? CGFloat(app.scrollDistancePixels / maxScroll) : 0,
                                    color: .orange
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private var appColumnHeaderButton: some View {
        let isSelected = selectedAppSortMetric == .app
        return Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.2)) {
                if selectedAppSortMetric == .app {
                    selectedAppSortAscending.toggle()
                } else {
                    selectedAppSortMetric = .app
                    selectedAppSortAscending = true
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("应用")
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? .primary : .secondary)
                if isSelected {
                    Image(systemName: selectedAppSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 95, alignment: .leading)
        .help(isSelected
            ? "当前按应用名称\(selectedAppSortAscending ? "A-Z" : "Z-A")排序，点击切换"
            : "按应用名称排序")
    }

    private func appSortHeaderButton(title: String, metric: AppSortMetric, color: Color) -> some View {
        let isSelected = selectedAppSortMetric == metric
        return Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.2)) {
                if selectedAppSortMetric == metric {
                    selectedAppSortAscending.toggle()
                } else {
                    selectedAppSortMetric = metric
                    selectedAppSortAscending = false
                }
            }
        } label: {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? color : .secondary)
                if isSelected {
                    Image(systemName: selectedAppSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(color)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? color.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected
            ? "当前按\(title)\(selectedAppSortAscending ? "升序" : "降序")，点击切换"
            : "按\(title)降序排列")
    }

    private func appMetricBar(valueText: String, ratio: CGFloat, color: Color) -> some View {
        GeometryReader { g in
            let w: CGFloat = g.size.width
            let safeRatio: CGFloat = min(1.0, max(0.0, ratio))
            let barW: CGFloat = max(4.0, w * safeRatio)

            ZStack(alignment: .trailing) {
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.65))
                        .frame(width: barW, height: 16)
                    Spacer(minLength: 0)
                }

                Text(valueText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(height: 16)
    }

    // MARK: - App Icon Image Helper

    private struct AppIconImage: View {
        let bundleId: String

        var body: some View {
            if let img = icon(for: bundleId) {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .cornerRadius(3)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
        }

        private func icon(for bundleId: String) -> NSImage? {
            if bundleId.isEmpty || bundleId == "unknown" { return nil }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return nil
        }
    }

    // MARK: - Collapse Button & Shortcut Helper

    private func cardCollapseButton(isExpanded: Binding<Bool>) -> some View {
        Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Design.radiusS)
                        .fill(Color.secondary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded.wrappedValue ? "收起卡片" : "展开卡片")
    }

    private func isShortcutKey(_ keyName: String) -> Bool {
        if keyName == "Command ⌘" || keyName == "Shift ⇧" || keyName == "Option ⌥" || keyName == "Control ⌃" || keyName == "Fn 🌐" ||
           keyName == "⌘ Command" || keyName == "⌥ Option" || keyName == "⌃ Control" || keyName == "Fn / 🌐" || keyName.hasPrefix("⇧ Shift") {
            return false
        }
        return keyName.contains("⌘") || keyName.contains("⌥") || keyName.contains("⌃") || keyName.contains("⇧")
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Spacer()

            if showResetConfirm {
                HStack(spacing: 6) {
                    Text("确认清空今日数据？")
                        .font(.system(size: 10))
                        .foregroundColor(.red)

                    Button("确认") {
                        Haptics.levelChange()
                        service.resetToday()
                        showResetConfirm = false
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .buttonStyle(.plain)

                    Button("取消") {
                        showResetConfirm = false
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    Haptics.light()
                    showResetConfirm = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                        Text("重置今日")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重置今日统计数据")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
