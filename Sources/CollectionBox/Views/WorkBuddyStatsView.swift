import SwiftUI

struct WorkBuddyStatsView: View {
    @State private var selectedRange: StatsTimeRange = .today
    @State private var stats: WorkBuddyStats?
    @State private var trend: [TrendPoint] = []
    @State private var lastUpdated: Date?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hoverIndex: Int?
    private let service = WorkBuddyStatsService()

    var body: some View {
        VStack(spacing: 0) {
            rangePicker
            metricContent
            Divider()
            trendChart
            bottomBar
        }
        .frame(minWidth: 360, idealWidth: 400, minHeight: 300)
        .onAppear { refresh() }
    }

    // MARK: - Picker

    private var rangePicker: some View {
        Picker("时间范围", selection: $selectedRange) {
            ForEach(StatsTimeRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .onChange(of: selectedRange) { _, _ in refresh() }
    }

    // MARK: - Metrics

    @ViewBuilder
    private var metricContent: some View {
        if let stats = stats {
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    metricCard(value: stats.formattedTokens, label: "Token 消耗", trend: stats.tokenTrend)
                    metricCard(value: stats.formattedSessions, label: "会话数", trend: stats.sessionTrend)
                }

                // Dual-metric breakdown row
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        Text("净输入").foregroundStyle(.secondary)
                        Text(stats.formattedInput).fontWeight(.medium).foregroundStyle(.primary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 2) {
                        Text("缓存").foregroundStyle(.secondary)
                        Text(stats.formattedCache).fontWeight(.medium).foregroundStyle(.primary)
                        Text(String(format: "(%.0f%%)", stats.cacheHitRate))
                            .foregroundStyle(.green)
                            .font(.system(size: Design.micro, weight: .semibold))
                    }
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 2) {
                        Text("输出").foregroundStyle(.secondary)
                        Text(stats.formattedOutput).fontWeight(.medium).foregroundStyle(.primary)
                    }
                }
                .font(.system(size: Design.caption))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(Design.slotAlpha))
                .clipShape(Capsule())
                .help("Token 明细：\n净输入: \(formatExact(stats.freshInputTokens))\n缓存命中: \(formatExact(stats.cacheReadTokens)) (\(String(format: "%.1f%%", stats.cacheHitRate)))\n模型生成: \(formatExact(stats.outputTokens))\n上下文吞吐: \(formatExact(stats.currentTokens))")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if let error = errorMessage {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.vertical, 8)
        } else if isLoading {
            ProgressView().controlSize(.small).padding(.vertical, 10)
        } else {
            Text("未找到 ~/.workbuddy/projects 会话数据").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 10)
        }
    }

    private func metricCard(value: String, label: String, trend: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: Design.caption)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                if let trend = trend { trendView(trend) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusM)
    }

    private func trendView(_ value: Double) -> some View {
        let isUp = value > 0
        let isFlat = abs(value) < 0.1
        let color: Color = isFlat ? .secondary : (isUp ? .green : .red)
        let text = isFlat ? "-" : "\(isUp ? "↑" : "↓")\(String(format: "%.0f", abs(value)))%"
        return Text(text).font(.system(size: Design.caption, weight: .medium)).foregroundStyle(color)
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        let maxTokens = trend.map(\.tokens).max() ?? 1

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Token 消耗趋势")
                    .font(.system(size: Design.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let idx = hoverIndex, idx < trend.count {
                    Text("\(trend[idx].label)  \(fmtToken(trend[idx].tokens))")
                        .font(.system(size: Design.caption, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            GeometryReader { geo in
                let canvasW = geo.size.width - 38  // 34 for Y-axis + some spacing
                let canvasH = geo.size.height

                HStack(spacing: 0) {
                    // Y-axis
                    VStack(alignment: .trailing, spacing: 0) {
                        Spacer().frame(height: 4)
                        Text(fmtToken(maxTokens))
                            .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(fmtToken(maxTokens / 2))
                            .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("0")
                            .font(.system(size: Design.micro)).foregroundStyle(.tertiary)
                        Spacer().frame(height: 4)
                    }
                    .frame(width: 34)

                    // Chart canvas
                    ZStack {
                        Canvas { context, size in
                            let n = trend.count
                            guard n > 0, maxTokens > 0 else { return }

                            let baselineY: CGFloat = size.height - 4
                            let drawH = baselineY - 4
                            let drawW = size.width - 4
                            let stepX = n > 1 ? drawW / CGFloat(n - 1) : drawW

                            for ratio in [0.0, 0.5, 1.0] {
                                let y = baselineY - drawH * ratio
                                var gp = Path()
                                gp.move(to: CGPoint(x: 0, y: y))
                                gp.addLine(to: CGPoint(x: drawW, y: y))
                                context.stroke(gp, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
                            }

                            guard n > 1 else {
                                let x = drawW / 2
                                let y = baselineY - drawH * (CGFloat(trend[0].tokens) / CGFloat(maxTokens))
                                let r: CGFloat = 3
                                context.fill(Path(ellipseIn: CGRect(x: x-r, y: y-r, width: r*2, height: r*2)), with: .color(.accentColor))
                                return
                            }

                            var pts: [CGPoint] = []
                            for (i, pt) in trend.enumerated() {
                                let x = stepX * CGFloat(i)
                                let y = baselineY - drawH * (CGFloat(pt.tokens) / CGFloat(maxTokens))
                                pts.append(CGPoint(x: x, y: y))
                            }

                            var fill = Path()
                            fill.move(to: CGPoint(x: pts[0].x, y: baselineY))
                            for p in pts { fill.addLine(to: p) }
                            fill.addLine(to: CGPoint(x: pts.last!.x, y: baselineY))
                            fill.closeSubpath()
                            let grad = Gradient(colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.01)])
                            context.fill(fill, with: .linearGradient(grad, startPoint: CGPoint(x: 0, y: 4), endPoint: CGPoint(x: 0, y: baselineY)))

                            var line = Path()
                            line.move(to: pts[0])
                            for p in pts.dropFirst() { line.addLine(to: p) }
                            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)

                            for (i, p) in pts.enumerated() {
                                let active = hoverIndex == i
                                let hasData = trend[i].tokens > 0
                                let r: CGFloat = active ? 4 : (hasData ? 2 : 0)
                                guard r > 0 else { continue }
                                let rect = CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)
                                context.fill(Path(ellipseIn: rect), with: .color(active ? .white : .accentColor))
                                if active {
                                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(.accentColor), lineWidth: 1.5)
                                }
                            }

                            if let idx = hoverIndex, idx < pts.count {
                                var vl = Path()
                                vl.move(to: CGPoint(x: pts[idx].x, y: 4))
                                vl.addLine(to: CGPoint(x: pts[idx].x, y: baselineY))
                                context.stroke(vl, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                            }
                        }

                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let n = trend.count
                                    guard n > 1, canvasW > 0 else { hoverIndex = nil; return }
                                    let drawW = canvasW - 4
                                    let stepX = drawW / CGFloat(n - 1)
                                    let rawIdx = loc.x / stepX
                                    hoverIndex = max(0, min(n - 1, Int(round(rawIdx))))
                                case .ended:
                                    hoverIndex = nil
                                }
                            }
                    }
                    .frame(width: canvasW, height: canvasH)
                }
            }
            .frame(height: 130)
            .padding(.horizontal, 12)
            if trend.count <= 14 {
                HStack(spacing: 0) {
                    ForEach(trend) { pt in
                        Text(pt.label)
                            .font(.system(size: Design.micro))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 8)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(trend.enumerated()), id: \.element.id) { i, pt in
                        Text((i % 5 == 0 || i == trend.count - 1) ? pt.label : "")
                            .font(.system(size: Design.micro))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 8)
            }
        }
        .padding(.bottom, 2)
    }

    private func fmtToken(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.1fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1000 { return String(format: "%.1fK", Double(tokens) / 1000) }
        return "\(tokens)"
    }

    private func formatExact(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if let last = lastUpdated {
                Text("上次更新 \(last, style: .time)")
                    .font(.system(size: Design.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("刷新数据")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func refresh() {
        errorMessage = nil
        hoverIndex = nil
        isLoading = true
        stats = nil
        let range = selectedRange
        // Scanning session files touches hundreds of MB at worst — keep it
        // off the main thread.
        Task.detached(priority: .userInitiated) {
            let newStats = service.fetchStats(for: range)
            let newTrend = service.fetchTrend(for: range)
            await MainActor.run {
                guard range == selectedRange else { return }
                stats = newStats
                trend = newTrend
                isLoading = false
                lastUpdated = Date()
            }
        }
    }
}
