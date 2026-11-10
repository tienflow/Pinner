import SwiftUI
import AppKit

// MARK: - Metric and Range Types (Aligned with InputStats)

public enum TrafficHistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case days7 = 7
    case days30 = 30

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .days7: return "7天"
        case .days30: return "30天"
        }
    }
}

public enum TrafficChartType: String, CaseIterable, Identifiable, Sendable {
    case line = "line"
    case bar = "bar"

    public var id: String { rawValue }
}

public enum TrafficMetricType: String, CaseIterable, Identifiable, Sendable {
    case total = "总流量"
    case download = "下载量"
    case upload = "上传量"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .total: return "chart.bar.xaxis"
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        }
    }

    public func value(from summary: TrafficMonitorService.TrafficDaySummary) -> Double {
        switch self {
        case .total: return Double(summary.total)
        case .download: return Double(summary.received)
        case .upload: return Double(summary.sent)
        }
    }
}

@MainActor
public struct TrafficView: View {
    @ObservedObject private var service: TrafficMonitorService
    var onClose: () -> Void

    // 24-Hour Hourly Flow Rhythm State
    @State private var isHourlyExpanded: Bool = true
    @State private var hoveredHour: Int? = nil

    // Historical Trend State
    @State private var selectedRange: TrafficHistoryRange = .days7
    @State private var selectedMetric: TrafficMetricType = .total
    @State private var selectedChartType: TrafficChartType = .line
    @State private var hoveredDayIndex: Int? = nil
    @State private var isHistoryExpanded: Bool = true

    public init(service: TrafficMonitorService, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    public init(onClose: @escaping () -> Void) {
        self.service = TrafficMonitorService.shared
        self.onClose = onClose
    }

    private var items: [TrafficProcessItem] {
        service.displayProcessItems
    }

    private var record: TrafficDayRecord {
        service.selectedRecord
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.15)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // Hotspot Protection Alert Banner
                    if service.isHotspotActive {
                        hotspotProtectionBanner
                    }

                    // 1. Overview 4-Metric Cards Grid
                    overviewCardsGrid

                    // 2. 24-Hour Hourly Flow Rhythm (24小时心流节律)
                    hourlyFlowCard

                    // 3. Search & Filter Bar (支持全部网络 / Wi-Fi / 有线网卡)
                    searchAndFilterBar

                    // 4. Process Table Section (无 PID 列，对齐进程面板图标)
                    processTableSection

                    // 5. Historical Trend Card (7天 / 30天历史趋势，折线/柱状，面板最下方)
                    historyTrendCard

                    // 6. Clean Bottom Status
                    bottomStatusBar
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 640)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                onClose()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Header Bar (无采集中的 tag)

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("流量统计")
                .font(.system(size: 14, weight: .bold))

            Spacer()

            // Refresh Button
            PanelRefreshButton(isLoading: service.isLoading, helpText: "立即刷新网络采样") {
                Task {
                    await service.refresh()
                }
            }

            // Close Button
            PanelCloseButton(helpText: "关闭面板 (⎋ / ⌘W)") {
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Mobile Hotspot Protection Banner

    private var hotspotProtectionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("当前连接：\(service.hotspotName ?? "移动个人热点")")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)

                    Text("计费网络")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(Design.radiusS)
                }

                Text("已开启流量敏感保护 · 建议暂停大文件下载与系统后台更新以保护手机流量")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if service.isConstrainedNetwork {
                HStack(spacing: 3) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 9))
                    Text("低数据模式")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusM)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
                )
        )
    }

    // MARK: - Overview Cards Grid (4 Cards)

    private var overviewCardsGrid: some View {
        HStack(spacing: 10) {
            // Card 1: 实时速率
            let downStr = TrafficBytes.formatSpeed(service.currentDownloadRate)
            let upStr = TrafficBytes.formatSpeed(service.currentUploadRate)
            overviewCard(
                title: "实时整机速率",
                value: "↓ \(downStr)",
                sub: "↑ \(upStr)",
                icon: "waveform.path.ecg",
                color: .blue,
                badgeText: "实时"
            )

            // Card 2: 周期总流量
            let hours = record.monitoredSeconds / 3600.0
            overviewCard(
                title: "\(service.currentPeriod.label)总流量",
                value: TrafficBytes.format(record.physical.total),
                sub: "覆盖监控 \(String(format: "%.1f", hours)) 小时",
                icon: "chart.bar.xaxis",
                color: .teal,
                badgeText: service.currentPeriod.label
            )

            // Card 3: 周期下载
            let dlRatio = record.physical.total > 0 ? Int(Double(record.physical.received) / Double(record.physical.total) * 100) : 0
            overviewCard(
                title: "下载接收",
                value: TrafficBytes.format(record.physical.received),
                sub: "占比 \(dlRatio)% · 物理网卡汇总",
                icon: "arrow.down.circle",
                color: .green,
                badgeText: "下行"
            )

            // Card 4: 周期上传
            let ulRatio = record.physical.total > 0 ? Int(Double(record.physical.sent) / Double(record.physical.total) * 100) : 0
            overviewCard(
                title: "上传发送",
                value: TrafficBytes.format(record.physical.sent),
                sub: "占比 \(ulRatio)% · 物理网卡汇总",
                icon: "arrow.up.circle",
                color: .purple,
                badgeText: "上行"
            )
        }
    }

    private func overviewCard(
        title: String,
        value: String,
        sub: String,
        icon: String,
        color: Color,
        badgeText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let badge = badgeText {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.12))
                        .cornerRadius(Design.radiusS)
                }
            }

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(sub)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(Design.radiusM)
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .stroke(color.opacity(0.18), lineWidth: 0.8)
        )
    }

    // MARK: - 24-Hour Hourly Flow Rhythm (对齐键鼠统计心流节律)

    private var hourlyFlowCard: some View {
        let hourlyData = service.todayHourlyTrendData()
        let maxActivity = hourlyData.map(\.total).max() ?? 0
        let peakBucket = hourlyData.max(by: { $0.total < $1.total })
        let peakTotal = peakBucket?.total ?? 0

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

                if let sel = service.selectedHour {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 9))
                        Text(String(format: "已锁定：%02d:00", sel))
                            .font(.system(size: Design.micro, weight: .semibold))
                        Button {
                            Haptics.light()
                            service.selectHour(nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .help("清除小时筛选")
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }

                if let peak = peakBucket, peakTotal > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                        Text(String(format: "高峰：%02d:00 (%@)", peak.hour, TrafficBytes.format(peakTotal)))
                            .font(.system(size: Design.micro, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                }

                Spacer()

                if let h = hoveredHour, h < hourlyData.count {
                    let b = hourlyData[h]
                    let isHPeak = (peakTotal > 0 && peakBucket?.hour == h)
                    Text(String(format: "%02d:00 · ↓ %@ · ↑ %@%@", h, TrafficBytes.format(b.received), TrafficBytes.format(b.sent), isHPeak ? " 🔥" : ""))
                        .font(.system(size: Design.micro, weight: .medium))
                        .foregroundColor(.primary)
                }

                cardCollapseButton(isExpanded: $isHourlyExpanded)
            }

            if isHourlyExpanded {
                let hasSelection = service.selectedHour != nil

                VStack(spacing: 4) {
                    GeometryReader { geo in
                        let spacing: CGFloat = 3
                        let totalSpacing = CGFloat(23) * spacing
                        let barWidth = max(4, (geo.size.width - totalSpacing) / 24)
                        let chartHeight: CGFloat = 46

                        HStack(alignment: .bottom, spacing: spacing) {
                            ForEach(hourlyData, id: \.hour) { b in
                                let total = b.total
                                let ratio: CGFloat = maxActivity > 0 ? (CGFloat(total) / CGFloat(maxActivity)) : 0.0
                                let rawH: CGFloat = ratio * chartHeight
                                let barH: CGFloat = total > 0 ? max(4.0, rawH) : 2.0
                                let isHovered = hoveredHour == b.hour
                                let isSelected = service.selectedHour == b.hour
                                let isPeak = peakTotal > 0 && peakBucket?.hour == b.hour && total > 0

                                let barColor: Color = {
                                    if total == 0 {
                                        return Color.secondary.opacity(0.10)
                                    }
                                    if isPeak {
                                        if hasSelection && !isSelected {
                                            return Color.orange.opacity(0.60)
                                        }
                                        return isHovered ? Color.orange.opacity(0.9) : Color.orange
                                    }
                                    if isSelected {
                                        return Color.accentColor
                                    }
                                    if hasSelection {
                                        return Color.accentColor.opacity(0.40)
                                    }
                                    return isHovered ? Color.accentColor : Color.accentColor.opacity(0.70)
                                }()

                                ZStack(alignment: .bottom) {
                                    // 选中或悬停时的整列轻柔背景槽，对齐 macOS 原生图表选区
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .fill((isPeak ? Color.orange : Color.accentColor).opacity(0.15))
                                            .frame(width: barWidth + 2.5, height: chartHeight + 2)
                                    } else if isHovered {
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .fill(Color.primary.opacity(0.04))
                                            .frame(width: barWidth + 2.5, height: chartHeight + 2)
                                    }

                                    // 数据柱体：干净纯粹，无粗硬描边与模糊阴影
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(barColor)
                                        .frame(width: barWidth, height: barH)
                                }
                                .frame(width: barWidth, height: chartHeight, alignment: .bottom)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Haptics.light()
                                    service.selectHour(b.hour)
                                }
                                .onHover { over in
                                    hoveredHour = over ? b.hour : nil
                                }
                                .help(String(format: "%02d:00%@ · 点击穿透查看进程排行 (总计 %@)", b.hour, isPeak ? " (高峰)" : "", TrafficBytes.format(total)))
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

    // MARK: - Historical Trend Card (对齐键鼠统计历史趋势卡片)

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
                    ForEach(TrafficHistoryRange.allCases) { r in
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
                // Metric Selector Pills: [总流量 | 下载量 | 上传量]
                HStack(spacing: 6) {
                    ForEach(TrafficMetricType.allCases) { m in
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
                        Text(TrafficBytes.format(UInt64(total)))
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
                        Text(TrafficBytes.format(UInt64(avg)))
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
                            Text(TrafficBytes.format(UInt64(itemVal)))
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

    private func chartTypeButton(type: TrafficChartType, icon: String) -> some View {
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

    private func barChartView(series: [TrafficMonitorService.TrafficDaySummary], values: [Double], safeMax: Double) -> some View {
        let count = series.count
        let chartHeight: CGFloat = 80

        return GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let spacing: CGFloat = count > 14 ? 2.0 : 6.0
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

    private func lineChartView(series: [TrafficMonitorService.TrafficDaySummary], values: [Double], safeMax: Double) -> some View {
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
                                    Circle().stroke(Color.accentColor, lineWidth: isHovered ? 2 : 0)
                                )
                                .position(pt)
                        }
                    }
                }

                // Invisible hit test columns
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { idx in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onHover { over in
                                hoveredDayIndex = over ? idx : nil
                            }
                    }
                }
            }
        }
        .frame(height: 80)
    }

    private func xAxisLabels(series: [TrafficMonitorService.TrafficDaySummary]) -> some View {
        HStack {
            if let first = series.first {
                Text(first.shortDateLabel).font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            Spacer()
            if series.count > 10, let mid = series[safe: series.count / 2] {
                Text(mid.shortDateLabel).font(.system(size: 8)).foregroundStyle(.tertiary)
                Spacer()
            }
            if let last = series.last {
                Text(last.shortDateLabel).font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 12)
    }

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

    // MARK: - Search & Filter Bar (支持 Wi-Fi 与有线网卡区分)

    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            // Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("搜索进程名或应用…", text: $service.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !service.searchText.isEmpty {
                    Button {
                        service.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(Design.radiusS)
            .overlay(
                RoundedRectangle(cornerRadius: Design.radiusS)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
            )

            Spacer()

            // Period Segment
            HStack(spacing: 3) {
                ForEach(TrafficPeriod.allCases) { period in
                    let isSelected = service.currentPeriod == period
                    Button {
                        Haptics.light()
                        service.currentPeriod = period
                    } label: {
                        Text(period.label)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .cornerRadius(Design.radiusS)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .cornerRadius(Design.radiusS + 2)

            // Network Selector Menu (清晰区分 Wi-Fi 和 有线网卡)
            Menu {
                Button("全部网络") {
                    service.selectedNetwork = "__all__"
                }
                ForEach(service.availableNetworkNames.filter { $0 != "全部网络" }, id: \.self) { netName in
                    Button {
                        service.selectedNetwork = netName
                    } label: {
                        HStack {
                            Image(systemName: netName.contains("Wi-Fi") ? "wifi" : "cable.connector.horizontal")
                            Text(netName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: service.selectedNetwork.contains("Wi-Fi") ? "wifi" : (service.selectedNetwork == "__all__" ? "network" : "cable.connector.horizontal"))
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(service.selectedNetwork == "__all__" ? "全部网络" : service.selectedNetwork)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
                .cornerRadius(Design.radiusS)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Process Table Section (无 PID 列，对齐进程面板图标)

    private var processTableSection: some View {
        VStack(spacing: 0) {
            if let selH = service.selectedHour {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(String(format: "已锁定查看 %02d:00 - %02d:59 时段活跃进程", selH, selH))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Button("恢复全天排行") {
                        Haptics.light()
                        service.selectHour(nil)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))

                Divider().opacity(0.15)
            }

            tableHeaderRow

            Divider().opacity(0.2)

            let processList = items
            if processList.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: service.searchText.isEmpty ? "chart.bar" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.top, 40)
                    Text(service.searchText.isEmpty ? "当前周期暂无进程流量记录" : "未找到匹配的进程")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
            } else {
                let maxTotal = max(1, processList.first?.bytes.total ?? 1)
                LazyVStack(spacing: 0) {
                    ForEach(Array(processList.enumerated()), id: \.element.id) { index, item in
                        processRow(index: index + 1, item: item, maxTotal: maxTotal)
                        Divider().opacity(0.08)
                    }

                    let residual = unattributedBytes(items: processList)
                    if residual.total > 512 * 1024 {
                        Divider().opacity(0.08)
                        unattributedRow(residual: residual, maxTotal: maxTotal)
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .cornerRadius(Design.radiusM)
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 8) {
            Text("#")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .center)

            headerSortCell(title: "进程 / 应用", field: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            headerSortCell(title: "下载量", field: .download, alignment: .trailing)
                .frame(width: 95, alignment: .trailing)

            headerSortCell(title: "上传量", field: .upload, alignment: .trailing)
                .frame(width: 95, alignment: .trailing)

            headerSortCell(title: "总流量", field: .total, alignment: .trailing)
                .frame(width: 105, alignment: .trailing)

            Text("占比")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.25))
    }

    private func headerSortCell(title: String, field: TrafficSortField, alignment: Alignment) -> some View {
        Button {
            Haptics.light()
            if service.sortField == field {
                service.sortAscending.toggle()
            } else {
                service.sortField = field
                service.sortAscending = (field == .name)
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(service.sortField == field ? .accentColor : .secondary)

                if service.sortField == field {
                    Image(systemName: service.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
    }

    /// 整机口径与进程排行之间的差额：连接在两次采样之间关闭时，其字节只留在网卡计数里
    private func unattributedBytes(items: [TrafficProcessItem]) -> TrafficBytes {
        let physical: TrafficBytes
        if let hour = service.selectedHour {
            physical = record.hourly[hour] ?? TrafficBytes()
        } else {
            physical = record.physical
        }
        let received = items.reduce(UInt64(0)) { $0 + $1.bytes.received }
        let sent = items.reduce(UInt64(0)) { $0 + $1.bytes.sent }
        return TrafficBytes(
            received: physical.received > received ? physical.received - received : 0,
            sent: physical.sent > sent ? physical.sent - sent : 0
        )
    }

    private func unattributedRow(residual: TrafficBytes, maxTotal: UInt64) -> some View {
        HStack(spacing: 8) {
            Text("—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.45))
                .frame(width: 24, alignment: .center)

            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("未归属（采样缺口）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("连接在采样间隔内关闭，字节只计入整机总量")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("该部分流量已计入整机总量，但对应连接在两次采样之间关闭，无法归属到具体进程")

            Text(TrafficBytes.format(residual.received))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)

            Text(TrafficBytes.format(residual.sent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)

            Text(TrafficBytes.format(residual.total))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .frame(width: 105, alignment: .trailing)

            GeometryReader { geo in
                let ratio = Double(residual.total) / Double(maxTotal)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: max(3, geo.size.width * min(1, ratio)), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 110, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
    }

    private func processRow(index: Int, item: TrafficProcessItem, maxTotal: UInt64) -> some View {
        HStack(spacing: 8) {
            // Index Number
            Text("\(index)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 24, alignment: .center)

            // App Icon & Name (参考 ProcessManager 规范)
            HStack(spacing: 8) {
                processIconView(for: item)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if item.isRelay {
                            Text("代理")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(Design.radiusS)
                                .help("该进程在转发其他应用的流量：已按回环计量回填到对应应用名下，这里仅显示未归属余量")
                        }

                        if !item.isRelay && item.proxied.total > 0 {
                            Text("经代理")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.teal)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.teal.opacity(0.12))
                                .cornerRadius(Design.radiusS)
                                .help("其中 \(TrafficBytes.format(item.proxied.total)) 经本地代理转发，已按回环计量回填到本应用")
                        }

                        if service.isHotspotActive && item.bytes.total >= 30 * 1024 * 1024 {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 7))
                                Text("热点大消耗")
                                    .font(.system(size: 8.5, weight: .semibold))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(Design.radiusS)
                            .help("当前处于移动热点环境，该应用已消耗超过 30MB 流量")
                        }
                    }

                    if item.displayName != item.name {
                        Text(item.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Download
            Text(TrafficBytes.format(item.bytes.received))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)

            // Upload
            Text(TrafficBytes.format(item.bytes.sent))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 95, alignment: .trailing)

            // Total
            Text(TrafficBytes.format(item.bytes.total))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .frame(width: 105, alignment: .trailing)

            // Ratio Progress Bar
            GeometryReader { geo in
                let ratio = Double(item.bytes.total) / Double(maxTotal)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 5)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.teal],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 110, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Process Icon View (对齐 ProcessManager)

    @ViewBuilder
    private func processIconView(for item: TrafficProcessItem) -> some View {
        if let icon = service.resolveIcon(for: item) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .cornerRadius(4.5)
        } else if isCommandLineTool(item.name) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .frame(width: 20, height: 20)
        } else if isContainerTool(item.name) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 12))
                .foregroundColor(.blue)
                .frame(width: 20, height: 20)
        } else if isSystemDaemon(item.name) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
        } else if item.isRelay {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 20, height: 20)
        }
    }

    private func isCommandLineTool(_ name: String) -> Bool {
        let tools = ["node", "python", "java", "ssh", "git", "go", "cargo", "zsh", "bash", "fish", "curl", "wget", "rsync", "claude", "codex", "gemini"]
        return tools.contains(where: { name.lowercased().hasPrefix($0) })
    }

    private func isContainerTool(_ name: String) -> Bool {
        let tools = ["docker", "orbstack", "containerd", "podman"]
        return tools.contains(where: { name.lowercased().hasPrefix($0) })
    }

    private func isSystemDaemon(_ name: String) -> Bool {
        let daemons = ["launchd", "syslogd", "apsd", "mdnsresponder", "airportd", "symptomsd", "wifip2pd", "kdc", "trustd"]
        return daemons.contains(where: { name.lowercased().hasPrefix($0) })
    }

    // MARK: - Clean Bottom Status (无多余提示文案)

    private var bottomStatusBar: some View {
        HStack {
            Spacer()
            if let lastSample = service.lastSampleTime {
                Text("更新于 \(lastSample, formatter: timeFormatter)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
