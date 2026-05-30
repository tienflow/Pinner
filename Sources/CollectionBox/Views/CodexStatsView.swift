import SwiftUI

struct CodexStatsView: View {
    @State private var selectedRange: StatsTimeRange = .today
    @State private var stats: CodexStats?
    @State private var trend: [TrendPoint] = []
    @State private var lastUpdated: Date?
    @State private var errorMessage: String?
    @State private var hoverIndex: Int?
    private let service = CodexStatsService()

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
            HStack(spacing: 8) {
                metricCard(value: stats.formattedTokens, label: "Token 消耗", trend: stats.tokenTrend)
                metricCard(value: stats.formattedSessions, label: "会话数", trend: stats.sessionTrend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        } else if let error = errorMessage {
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.vertical, 8)
        } else {
            ProgressView().controlSize(.small).padding(.vertical, 10)
        }
    }

    private func metricCard(value: String, label: String, trend: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
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
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    private func trendView(_ value: Double) -> some View {
        let isUp = value > 0
        let isFlat = abs(value) < 0.1
        let color: Color = isFlat ? .secondary : (isUp ? .green : .red)
        let text = isFlat ? "-" : "\(isUp ? "↑" : "↓")\(String(format: "%.0f", abs(value)))%"
        return Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        let maxTokens = trend.map(\.tokens).max() ?? 1

        return VStack(alignment: .leading, spacing: 0) {
            // Title + hover info
            HStack {
                Text("Token 消耗趋势")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let idx = hoverIndex, idx < trend.count {
                    Text("\(trend[idx].label)  \(fmtToken(trend[idx].tokens))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Chart: Y-axis + Canvas + hover overlay
            GeometryReader { geo in
                let canvasW = geo.size.width - 38  // 34 for Y-axis + some spacing
                let canvasH = geo.size.height

                HStack(spacing: 0) {
                    // Y-axis
                    VStack(alignment: .trailing, spacing: 0) {
                        Spacer().frame(height: 4)
                        Text(fmtToken(maxTokens))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(fmtToken(maxTokens / 2))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                        Spacer()
                        Text("0")
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
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

                            // Grid
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

                            // Gradient fill
                            var fill = Path()
                            fill.move(to: CGPoint(x: pts[0].x, y: baselineY))
                            for p in pts { fill.addLine(to: p) }
                            fill.addLine(to: CGPoint(x: pts.last!.x, y: baselineY))
                            fill.closeSubpath()
                            let grad = Gradient(colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.01)])
                            context.fill(fill, with: .linearGradient(grad, startPoint: CGPoint(x: 0, y: 4), endPoint: CGPoint(x: 0, y: baselineY)))

                            // Line
                            var line = Path()
                            line.move(to: pts[0])
                            for p in pts.dropFirst() { line.addLine(to: p) }
                            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)

                            // Dots
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

                            // Hover line
                            if let idx = hoverIndex, idx < pts.count {
                                var vl = Path()
                                vl.move(to: CGPoint(x: pts[idx].x, y: 4))
                                vl.addLine(to: CGPoint(x: pts[idx].x, y: baselineY))
                                context.stroke(vl, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                            }
                        }

                        // Transparent hover overlay
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
            // X-axis labels
            if trend.count <= 14 {
                HStack(spacing: 0) {
                    ForEach(trend) { pt in
                        Text(pt.label)
                            .font(.system(size: 7))
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
                            .font(.system(size: 7))
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if let last = lastUpdated {
                Text("上次更新 \(last, style: .time)")
                    .font(.system(size: 10))
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
        stats = service.fetchStats(for: selectedRange)
        trend = service.fetchTrend(for: selectedRange)
        lastUpdated = Date()
    }
}
