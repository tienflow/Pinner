import SwiftUI
import AppKit

public struct PortProcessDetailView: View {
    let process: PortProcessInfo
    @ObservedObject var service: PortManagerService
    var onClose: () -> Void

    @State private var commandLine: String = ""
    @State private var workingDirectory: String? = nil
    @State private var isLoadingCommandLine: Bool = true
    @State private var isTerminating: Bool = false
    @State private var errorMessage: String? = nil
    @State private var copiedPathToast: Bool = false
    @State private var copiedCwdToast: Bool = false

    public init(
        process: PortProcessInfo,
        service: PortManagerService,
        onClose: @escaping () -> Void
    ) {
        self.process = process
        self.service = service
        self.onClose = onClose
    }

    private var effectiveWorkingDirectory: String? {
        if let dir = workingDirectory ?? process.validWorkingDirectory {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "/" {
                return trimmed
            }
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Header
            headerSection

            // 3-Metric Cards Grid (Port, Memory, CPU)
            metricsGrid

            // Path, Working Directory & Command Line
            ScrollView(.vertical, showsIndicators: false) {
                detailsCard
            }

            if let error = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: Design.ui))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.12))
                .cornerRadius(Design.radiusS)
            }

            Spacer(minLength: 0)

            // Bottom Actions Bar
            bottomActionsBar
        }
        .padding(20)
        .frame(width: 500, height: 460)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .task {
            isLoadingCommandLine = true
            workingDirectory = process.validWorkingDirectory
            async let cmdTask = service.fetchCommandLine(for: process.pid)
            async let cwdTask: String? = (process.validWorkingDirectory == nil)
                ? service.fetchWorkingDirectory(for: process.pid)
                : process.validWorkingDirectory
            commandLine = await cmdTask
            if let resolvedCwd = await cwdTask {
                workingDirectory = resolvedCwd
            }
            isLoadingCommandLine = false
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // App Icon
            processIconView
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(process.displayName)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)

                    // PID Badge
                    Text("PID: \(process.pid)")
                        .font(.system(size: Design.ui, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(Design.slotAlpha))
                        .cornerRadius(Design.radiusS)

                    if process.isRoot {
                        Text("ROOT")
                            .font(.system(size: Design.micro, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.15))
                            .cornerRadius(Design.radiusS)
                    }
                }

                HStack(spacing: 8) {
                    // Status Badge
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("监听中")
                            .font(.system(size: Design.ui, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    // Network Exposure Badge
                    if process.isExposed {
                        HStack(spacing: 3) {
                            Image(systemName: "globe")
                                .font(.system(size: 7.5))
                            Text("局域网暴露")
                                .font(.system(size: Design.micro, weight: .semibold))
                        }
                        .foregroundColor(.teal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.teal.opacity(0.14))
                        .cornerRadius(Design.radiusS)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7))
                            Text("本机隔离")
                                .font(.system(size: Design.micro, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(Design.radiusS)
                    }

                    // Category Badge
                    HStack(spacing: 3) {
                        Image(systemName: process.category.icon)
                            .font(.system(size: 9))
                        Text(process.category.rawValue)
                            .font(.system(size: Design.micro, weight: .medium))
                    }
                    .foregroundColor(categoryColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(categoryColor.opacity(0.12))
                    .cornerRadius(Design.radiusS)
                }
            }

            Spacer()

            // Close button
            PanelCloseButton(helpText: "关闭详情 (⎋)") {
                onClose()
            }
        }
    }

    private var categoryColor: Color {
        switch process.category {
        case .devServer: return .blue
        case .docker: return .teal
        case .userApp: return .purple
        case .systemDaemon: return .secondary
        }
    }

    private var processIconView: some View {
        if process.category == .docker {
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.teal.opacity(0.18))
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.teal)
                }
            )
        }

        let icon = PortManagerService.resolveProcessIcon(for: process)

        return AnyView(
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .cornerRadius(8)
        )
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        HStack(spacing: 10) {
            // Port Card
            metricCard(title: process.ports.count > 1 ? "监听端口 (\(process.ports.count))" : "监听端口") {
                HStack(alignment: .center, spacing: 4) {
                    Text(":\(process.ports.first.map(String.init) ?? "--")")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .fixedSize()

                    Text(process.protocolType.lowercased())
                        .font(.system(size: Design.micro, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(Design.slotAlpha))
                        .cornerRadius(3)

                    if process.ports.count > 1 {
                        Text("+\(process.ports.count - 1)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(Design.slotAlpha))
                            .cornerRadius(3)
                            .help("全部端口: \(process.portsDisplayString)")
                    }

                    Spacer(minLength: 2)

                    if let firstPort = process.ports.first {
                        Button {
                            service.openInBrowser(port: firstPort)
                        } label: {
                            Image(systemName: "safari")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.blue)
                                .frame(width: 22, height: 22)
                                .background(Color.blue.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("在浏览器打开 (http://localhost:\(firstPort))")
                    }
                }
            }

            // Memory Card
            metricCard(title: "内存占用") {
                Text(process.memoryDisplayString)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            // CPU Card
            metricCard(title: "CPU 使用率") {
                Text(String(format: "%.1f%%", process.cpuPercent))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(process.cpuPercent > 50 ? .orange : .primary)
                    .lineLimit(1)
            }
        }
    }

    private func metricCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: Design.caption, weight: .medium))
                .foregroundColor(.secondary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(Design.hoverAlpha))
        .cornerRadius(Design.radiusM)
    }

    // MARK: - Path, Working Directory and Command Line Card

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Quick Browser Launch Strip for Listening Ports
            if let firstPort = process.ports.first {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("本地服务直达")
                        .font(.system(size: Design.caption, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()

                    Button {
                        service.openInBrowser(port: firstPort)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: 10))
                            Text("在浏览器打开 (http://localhost:\(firstPort))")
                                .font(.system(size: Design.micro, weight: .medium, design: .monospaced))
                                .lineLimit(1)
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.10))
                        .cornerRadius(Design.radiusS)
                    }
                    .buttonStyle(.plain)
                    .help("在默认浏览器中打开 http://localhost:\(firstPort)")

                    ForEach(Array(process.ports.dropFirst().prefix(2)), id: \.self) { port in
                        Button {
                            service.openInBrowser(port: port)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "safari")
                                    .font(.system(size: 9))
                                Text(":\(port)")
                                    .font(.system(size: Design.micro, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.10))
                            .cornerRadius(Design.radiusS)
                        }
                        .buttonStyle(.plain)
                        .help("在默认浏览器中打开 http://localhost:\(port)")
                    }
                }
            }

            // Working Directory / Project Path (when available and != "/")
            if let cwd = effectiveWorkingDirectory {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        Text("工作目录 / 项目路径")
                            .font(.system(size: Design.caption, weight: .medium))
                            .foregroundColor(.secondary)

                        if let folderName = (cwd as NSString).lastPathComponent as String?, !folderName.isEmpty {
                            Text(folderName)
                                .font(.system(size: Design.micro, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(3)
                        }

                        Spacer()

                        if copiedCwdToast {
                            Text("已拷贝")
                                .font(.system(size: Design.micro, weight: .medium))
                                .foregroundColor(.green)
                        }

                        Button {
                            service.openProjectDirectory(path: cwd)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text("打开项目目录")
                                    .font(.system(size: Design.micro, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(Design.hoverAlpha))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中打开该进程所在工作目录")

                        Button {
                            service.openInTerminal(path: cwd)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 9))
                                Text("在终端打开")
                                    .font(.system(size: Design.micro, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.primary.opacity(Design.hoverAlpha))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("在终端中打开此工作目录")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cwd, forType: .string)
                        Haptics.light()
                        copiedCwdToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedCwdToast = false
                        }
                    } label: {
                        Text(cwd)
                            .font(.system(size: Design.ui, design: .monospaced))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(Design.slotAlpha))
                            .cornerRadius(Design.radiusS)
                    }
                    .buttonStyle(.plain)
                    .help("点击拷贝工作目录路径")
                }
            }

            // All Ports if multiple
            if process.ports.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "network")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("全部监听端口 (\(process.ports.count))")
                            .font(.system(size: Design.caption, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    Text(process.portsDisplayString)
                        .font(.system(size: Design.ui, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(Design.slotAlpha))
                        .cornerRadius(Design.radiusS)
                }
            }

            // Executable Path
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("进程路径")
                        .font(.system(size: Design.caption, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    if copiedPathToast {
                        Text("已拷贝")
                            .font(.system(size: Design.micro, weight: .medium))
                            .foregroundColor(.green)
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(process.fullPath, forType: .string)
                    Haptics.light()
                    copiedPathToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedPathToast = false
                    }
                } label: {
                    Text(process.fullPath.isEmpty ? "未找到路径" : process.fullPath)
                        .font(.system(size: Design.ui, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(Design.slotAlpha))
                        .cornerRadius(Design.radiusS)
                }
                .buttonStyle(.plain)
                .help("点击拷贝完整路径")
            }

            // Command Line if available
            if !commandLine.isEmpty && commandLine != process.fullPath {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("运行命令")
                            .font(.system(size: Design.caption, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Text(commandLine)
                        .font(.system(size: Design.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(Design.slotAlpha))
                        .cornerRadius(Design.radiusS)
                }
            }
        }
    }

    // MARK: - Bottom Actions

    private var bottomActionsBar: some View {
        HStack(spacing: 10) {
            // Open file location button
            Button {
                service.revealInFinder(path: process.fullPath)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 11))
                    Text("打开文件位置")
                        .font(.system(size: Design.ui, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(Design.hoverAlpha))
                .cornerRadius(Design.radiusS)
            }
            .buttonStyle(.plain)
            .disabled(process.fullPath.isEmpty)

            if let cwd = effectiveWorkingDirectory {
                Button {
                    service.openProjectDirectory(path: cwd)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("打开项目目录")
                            .font(.system(size: Design.ui, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(Design.hoverAlpha))
                    .cornerRadius(Design.radiusS)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Close
            Button {
                onClose()
            } label: {
                Text("关闭")
                    .font(.system(size: Design.ui, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(Design.hoverAlpha))
                    .cornerRadius(Design.radiusS)
            }
            .buttonStyle(.plain)

            // Force Kill / Stop Docker Button
            Button {
                terminateCurrentProcess()
            } label: {
                HStack(spacing: 5) {
                    if isTerminating {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: process.category == .docker ? "stop.circle.fill" : "slash.circle.fill")
                            .font(.system(size: 11))
                    }
                    Text(process.category == .docker ? "停止 Docker 容器" : (process.isRoot ? "授权强制终止" : "强制终止进程"))
                        .font(.system(size: Design.ui, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red)
                .cornerRadius(Design.radiusS)
            }
            .buttonStyle(.plain)
            .disabled(isTerminating)
        }
    }

    private func terminateCurrentProcess() {
        isTerminating = true
        errorMessage = nil
        Task {
            let res = await service.terminateProcess(process: process, force: true)
            isTerminating = false
            switch res {
            case .success:
                onClose()
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }
}
