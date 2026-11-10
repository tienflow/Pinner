import SwiftUI
import AppKit

struct SystemDiagnosticSheet: View {
    let report: SystemDiagnosticReport?
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void
    let onAction: (DiagnosticActionType, pid_t?) -> Void
    let onClose: () -> Void

    init(
        report: SystemDiagnosticReport?,
        isLoading: Bool,
        errorMessage: String?,
        onRetry: @escaping () -> Void,
        onAction: @escaping (DiagnosticActionType, pid_t?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.report = report
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRetry = onRetry
        self.onAction = onAction
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("系统卡顿与进程 AI 急救")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                if let r = report {
                    statusBadge(r.statusLevel)
                }

                PanelCloseButton(helpText: "关闭诊断 (⎋)") {
                    onClose()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.15)

            // Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        loadingView
                    } else if let error = errorMessage {
                        errorView(error)
                    } else if let r = report {
                        reportContent(r)
                    }
                }
                .padding(16)
            }

            // Bottom Actions Bar
            if let r = report, !isLoading {
                Divider().opacity(0.15)
                bottomBar(r)
            }
        }
        .frame(width: 460, height: 420)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
    }

    // MARK: - Subviews

    private func statusBadge(_ level: DiagnosticStatusLevel) -> some View {
        let color: Color = level == .critical ? .red : (level == .warning ? .orange : .green)
        return HStack(spacing: 4) {
            Image(systemName: level.iconName)
                .font(.system(size: 10, weight: .bold))
            Text(level.rawValue)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(Design.radiusS)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 50)
            ProgressView()
                .scaleEffect(0.9)
            Text("正在分析系统内核快照与活跃进程…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text("采集 CPU 综合负载 · 统一内存压力 · 换页分析")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 30)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            Text("诊断暂不可用")
                .font(.system(size: 14, weight: .semibold))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button("重试") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func reportContent(_ r: SystemDiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 核心归因卡片
            VStack(alignment: .leading, spacing: 6) {
                Text("核心归因")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(r.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(Design.slotAlpha))
            .cornerRadius(Design.radiusM)

            // 事实发现
            if !r.findings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("事实观察")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(r.findings, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundColor(.accentColor)
                            Text(item)
                                .font(.system(size: 12))
                                .foregroundColor(.primary.opacity(0.9))
                        }
                    }
                }
            }

            // 处置建议
            if !r.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("调优与处置建议")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(r.recommendations, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                            Text(item)
                                .font(.system(size: 12))
                                .foregroundColor(.primary.opacity(0.9))
                        }
                    }
                }
            }
        }
    }

    private func bottomBar(_ r: SystemDiagnosticReport) -> some View {
        HStack(spacing: 10) {
            if let pid = r.targetPID, r.suggestedAction != .none {
                if r.suggestedAction == .suspend {
                    Button {
                        onAction(.suspend, pid)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pause.fill")
                            Text("一键挂起 PID \(pid)")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                } else if r.suggestedAction == .terminate {
                    Button {
                        onAction(.terminate, pid)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.octagon.fill")
                            Text("一键强杀 PID \(pid)")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }

            Spacer()

            Button("重新诊断") {
                onRetry()
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
