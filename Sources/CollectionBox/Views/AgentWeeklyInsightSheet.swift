import SwiftUI
import AppKit

struct AgentWeeklyInsightSheet: View {
    let insight: AgentWeeklyInsight?
    let snapshot: StatsDashboardView.DashboardSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let onRegenerate: () -> Void
    let onClose: () -> Void

    @State private var copiedToast: Bool = false
    @State private var loadingStartDate: Date = Date()

    private let pipelineSteps = [
        ("cylinder.split.1x2.fill", "正在汇聚 Codex / Antigravity / WorkBuddy 多 Agent 账本…"),
        ("bolt.shield.fill", "深度比对 Prompt Cache 命中率与 Top 重型会话…"),
        ("wrench.and.screwdriver.fill", "审计 35+ 本地技能调用频次与 30 天沉睡清单…"),
        ("sparkles", "正在由 AI 提炼极客深度洞察与提效行动清单…")
    ]

    init(
        insight: AgentWeeklyInsight?,
        snapshot: StatsDashboardView.DashboardSnapshot? = nil,
        isLoading: Bool,
        errorMessage: String?,
        onRegenerate: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.insight = insight
        self.snapshot = snapshot
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRegenerate = onRegenerate
        self.onClose = onClose
    }

    private var shouldShowLoading: Bool {
        isLoading || (insight == nil && errorMessage == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider().opacity(0.15)

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if shouldShowLoading {
                        dynamicLoadingView
                    } else if let error = errorMessage {
                        errorView(error)
                    } else if let ins = insight {
                        insightContent(ins)
                    }
                }
                .padding(20)
            }

            // Bottom Actions Bar
            if insight != nil && !shouldShowLoading {
                Divider().opacity(0.15)
                bottomBar
            }
        }
        .frame(width: 580, height: 560)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .onAppear {
            loadingStartDate = Date()
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                loadingStartDate = Date()
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.purple)

            Text(insight?.title ?? "多 Agent 协同周度智能洞察")
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)

            Spacer()

            if let date = insight?.createdAt, !shouldShowLoading {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.purple.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text("生成于 \(date, style: .time)")
                        .font(.system(size: Design.micro))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 4)
            }

            PanelCloseButton(helpText: "关闭洞察 (⎋)") {
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Dynamic Loading View with Pipeline Animation

    private var dynamicLoadingView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(loadingStartDate))
            let stepIndex = min(pipelineSteps.count - 1, Int(elapsed / 1.1) % pipelineSteps.count)
            let breath = 1.0 + 0.22 * CGFloat(0.5 + 0.5 * sin(elapsed * 3.2))
            let spinAngle = (elapsed * 140).truncatingRemainder(dividingBy: 360)

            VStack(spacing: 20) {
                Spacer().frame(height: 46)

                // Pulsing & Spinning Glow Symbol
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.purple.opacity(0.38), Color.blue.opacity(0.12), Color.clear],
                                center: .center,
                                startRadius: 5,
                                endRadius: 56
                            )
                        )
                        .frame(width: 104, height: 104)
                        .scaleEffect(breath)

                    Circle()
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 66, height: 66)
                        .overlay(
                            Circle().stroke(Color.purple.opacity(0.22), lineWidth: 1)
                        )

                    Circle()
                        .trim(from: 0.08, to: 0.72)
                        .stroke(
                            AngularGradient(
                                colors: [Color.purple.opacity(0.05), Color.blue.opacity(0.6), Color.purple],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .frame(width: 68, height: 68)
                        .rotationEffect(.degrees(spinAngle))

                    Image(systemName: pipelineSteps[stepIndex].0)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Step Description
                VStack(spacing: 8) {
                    Text(pipelineSteps[stepIndex].1)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .id(stepIndex)

                    Text("正在向模型请求多维洞察，耗时约 3~6 秒…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }

                // Step Progress Dots
                HStack(spacing: 6) {
                    ForEach(0..<pipelineSteps.count, id: \.self) { idx in
                        Capsule()
                            .fill(idx == stepIndex ? Color.purple : (idx < stepIndex ? Color.purple.opacity(0.45) : Color.secondary.opacity(0.2)))
                            .frame(width: idx == stepIndex ? 18 : 6, height: 5)
                    }
                }
                .padding(.top, 4)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Error View

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 50)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            Text("智能洞察生成失败")
                .font(.system(size: 14, weight: .semibold))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("重新生成") {
                onRegenerate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Structured Insight Content

    private func insightContent(_ ins: AgentWeeklyInsight) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Summary Highlight Banner
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.purple)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("核心摘要")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.purple.opacity(0.85))
                    Text(ins.summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineSpacing(3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: Design.radiusM)
                    .stroke(Color.purple.opacity(0.22), lineWidth: 0.8)
            )
            .cornerRadius(Design.radiusM)

            // Quick Metrics 4-Card Strip (If snapshot available)
            if let snap = snapshot {
                quickMetricsStrip(snap)
            }

            // High-fidelity Markdown Rendered Body
            MarkdownContentView(markdown: ins.contentMarkdown)
        }
    }

    private func quickMetricsStrip(_ snap: StatsDashboardView.DashboardSnapshot) -> some View {
        let totalAll = snap.inRangeTotalTokens > 0 ? snap.inRangeTotalTokens : 1
        let topAgent = StatsAgent.allCases
            .compactMap { a -> (StatsAgent, Int)? in
                let tok = snap.agentTokens[a] ?? 0
                return tok > 0 ? (a, tok) : nil
            }
            .sorted { $0.1 > $1.1 }
            .first

        let topAgentText: String
        let topAgentSub: String
        if let ta = topAgent {
            topAgentText = ta.0.label
            topAgentSub = String(format: "占比 %.0f%%", Double(ta.1) / Double(totalAll) * 100)
        } else {
            topAgentText = "暂无"
            topAgentSub = "0%"
        }

        let peakStr = snap.peakHour.map { String(format: "%02d:00", $0) } ?? "--"

        return HStack(spacing: 8) {
            metricCard(title: "7天总消耗", value: WorkBuddyStats.formatTokens(snap.d7Tokens), sub: "日均 \(WorkBuddyStats.formatTokens(snap.dailyAvgTokens))")
            metricCard(title: "黄金心流", value: peakStr, sub: "峰值吞吐 \(WorkBuddyStats.formatTokens(snap.peakHourTokens))")
            metricCard(title: "领跑 Agent", value: topAgentText, sub: topAgentSub)
            metricCard(title: "Prompt 缓存", value: String(format: "%.1f%%", snap.cacheHitRate), sub: "输入 \(WorkBuddyStats.formatTokens(snap.freshInput))")
        }
    }

    private func metricCard(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(sub)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(Design.slotAlpha))
        .cornerRadius(Design.radiusS)
    }

    // MARK: - Bottom Actions Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if copiedToast {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("已复制 Markdown 到剪贴板")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
                .transition(.opacity)
            }

            Spacer()

            Button {
                if let markdown = insight?.contentMarkdown {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    Haptics.levelChange()
                    withAnimation { copiedToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { copiedToast = false }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("复制 Markdown")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onRegenerate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新生成")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("完成") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - High-Fidelity Markdown Parser & Content View

struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseBlocks(markdown).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    enum Block {
        case header(level: Int, text: String)
        case callout(text: String)
        case listItem(text: String)
        case paragraph(text: String)
    }

    private func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("### ") {
                blocks.append(.header(level: 3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.header(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.header(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("> ") {
                blocks.append(.callout(text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.listItem(text: String(trimmed.dropFirst(2))))
            } else {
                blocks.append(.paragraph(text: trimmed))
            }
        }

        return blocks
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .header(_, let text):
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.purple)
                    .frame(width: 3.5, height: 13)

                Text(attributedText(text))
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.primary)
            }
            .padding(.top, 6)

        case .callout(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.purple)
                    .padding(.top, 1)

                Text(attributedText(text))
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(Design.slotAlpha))
            .cornerRadius(Design.radiusS)

        case .listItem(let text):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(Color.purple.opacity(0.8))
                    .frame(width: 4, height: 4)
                    .padding(.top, 6)

                Text(attributedText(text))
                    .font(.system(size: 12))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 6)

        case .paragraph(let text):
            Text(attributedText(text))
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.88))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attributedText(_ raw: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(raw)
    }
}
