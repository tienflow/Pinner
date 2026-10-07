import SwiftUI
import AppKit

@MainActor
public struct ProcessManagerView: View {
    @ObservedObject private var service: ProcessManagerService
    var onClose: () -> Void

    @State private var processPendingTermination: ManagedProcessEntry? = nil
    @State private var isTerminating: Bool = false
    @State private var terminationErrorMessage: String? = nil

    public init(service: ProcessManagerService = .shared, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    private var filteredProcesses: [ManagedProcessEntry] {
        var list = service.processes

        // 1. Filter option
        switch service.filterOption {
        case .devFirst:
            list = list.filter { proc in
                proc.category == .runtime ||
                proc.category == .devTool ||
                proc.category == .docker ||
                proc.cpuPercent > 1.0 ||
                proc.residentMemoryBytes > 300_000_000 ||
                proc.isSuspended
            }
        case .highLoad:
            list = list.filter { proc in
                proc.cpuPercent > 10.0 || proc.residentMemoryBytes > 1_000_000_000 || proc.isSuspended
            }
        case .all:
            break
        }

        // 2. Search Text
        let query = service.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter { proc in
                proc.displayName.lowercased().contains(query) ||
                String(proc.pid).contains(query) ||
                proc.name.lowercased().contains(query)
            }
        }

        // 3. Sorting
        return list.sorted { a, b in
            // Suspended processes remain visible
            if a.isSuspended != b.isSuspended {
                return a.isSuspended
            }
            switch service.sortField {
            case .cpu:
                return service.sortAscending ? a.cpuPercent < b.cpuPercent : a.cpuPercent > b.cpuPercent
            case .memory:
                return service.sortAscending ? a.residentMemoryBytes < b.residentMemoryBytes : a.residentMemoryBytes > b.residentMemoryBytes
            case .name:
                let comp = a.displayName.localizedStandardCompare(b.displayName)
                return service.sortAscending ? comp == .orderedAscending : comp == .orderedDescending
            case .pid:
                return service.sortAscending ? a.pid < b.pid : a.pid > b.pid
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.15)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // 1. Overview 3-Metric Pressure Cards
                    pressureCardsGrid

                    // 2. Search & Filter Bar
                    searchAndFilterBar

                    // 3. Process Table Section
                    processTableSection
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 600)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                onClose()
                return .handled
            }
            return .ignored
        }
        .confirmationDialog(
            "终止进程",
            isPresented: Binding(
                get: { processPendingTermination != nil },
                set: { if !$0 { processPendingTermination = nil } }
            ),
            presenting: processPendingTermination
        ) { proc in
            Button("强制终止 \(proc.displayName) (PID \(proc.pid))", role: .destructive) {
                executeTermination(for: proc)
            }
            Button("取消", role: .cancel) {
                processPendingTermination = nil
            }
        } message: { proc in
            Text("确定要终止 \(proc.displayName) (PID: \(proc.pid)) 吗？\n如果该进程有未保存的工作，可能会丢失数据。")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("进程管家")
                .font(.system(size: 14, weight: .bold))

            // Status Indicator Dot
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)

                Text("采样中 (2s)")
                    .font(.system(size: Design.micro, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.12))
            .cornerRadius(Design.radiusS)

            Spacer()

            PanelRefreshButton(isLoading: service.isLoading, helpText: "立即刷新系统诊断数据") {
                Task {
                    await service.refresh()
                }
            }

            PanelCloseButton(helpText: "关闭面板 (⎋ / ⌘W)") {
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Pressure Cards Grid (3 Cards)

    private var pressureCardsGrid: some View {
        HStack(spacing: 10) {
            // Card 1: CPU Load
            let cpuTotal = service.systemPressure.cpuTotalPercent
            let cpuColor: Color = cpuTotal > 80 ? .red : (cpuTotal > 50 ? .orange : .blue)
            pressureCard(
                title: "CPU 综合负载",
                value: String(format: "%.1f%%", cpuTotal),
                sub: "用户 \(Int(service.systemPressure.cpuUserPercent))% · 系统 \(Int(service.systemPressure.cpuSystemPercent))% (\(service.systemPressure.logicalCores)核)",
                icon: "cpu",
                color: cpuColor
            )

            // Card 2: Memory Pressure
            let memPressure = service.systemPressure.memoryPressure
            let memColor: Color = memPressure == .critical ? .red : (memPressure == .warning ? .orange : .green)
            pressureCard(
                title: "统一内存与压力",
                value: memPressure.rawValue,
                sub: "已用 \(service.systemPressure.memoryDisplayString)",
                icon: "memorychip",
                color: memColor
            )

            // Card 3: Swap Usage
            let swapBytes = service.systemPressure.swapUsedBytes
            let swapColor: Color = swapBytes > 1_000_000_000 ? .orange : .purple
            let swapSub = swapBytes > 1_000_000_000 ? "注意：正在发生磁盘换页" : "内存充裕 · 零磁盘换页"
            pressureCard(
                title: "磁盘 Swap 交换",
                value: service.systemPressure.swapDisplayString,
                sub: swapSub,
                icon: "arrow.triangle.swap",
                color: swapColor
            )
        }
    }

    private func pressureCard(
        title: String,
        value: String,
        sub: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(sub)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
        .cornerRadius(Design.radiusM)
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Search & Filter Bar

    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            // Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("搜索进程名、参数或 PID…", text: $service.searchText)
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

            // Filter Options
            HStack(spacing: 4) {
                ForEach(ProcessFilterOption.allCases) { opt in
                    Button {
                        Haptics.light()
                        service.filterOption = opt
                    } label: {
                        Text(opt.rawValue)
                            .font(.system(size: 11, weight: service.filterOption == opt ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(service.filterOption == opt ? Color.accentColor.opacity(0.18) : Color.clear)
                            .foregroundColor(service.filterOption == opt ? .accentColor : .secondary)
                            .cornerRadius(Design.radiusS)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .cornerRadius(Design.radiusS + 2)
        }
    }

    // MARK: - Process Table Section

    private var processTableSection: some View {
        VStack(spacing: 0) {
            // Table Header
            tableHeaderRow

            Divider().opacity(0.2)

            let procs = filteredProcesses
            if procs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 40)
                    Text(service.processes.isEmpty ? "正在采集系统进程…" : "未找到匹配的进程")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(procs) { proc in
                        processRow(proc)
                        Divider().opacity(0.08)
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
            // Process / Args
            headerSortCell(title: "进程 / 命令", field: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // PID
            headerSortCell(title: "PID", field: .pid, alignment: .center)
                .frame(width: 60, alignment: .center)

            // CPU %
            headerSortCell(title: "CPU", field: .cpu, alignment: .trailing)
                .frame(width: 75, alignment: .trailing)

            // Memory
            headerSortCell(title: "内存", field: .memory, alignment: .trailing)
                .frame(width: 85, alignment: .trailing)

            // Actions
            Text("操作")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.25))
    }

    private func headerSortCell(title: String, field: ProcessSortField, alignment: Alignment) -> some View {
        Button {
            Haptics.light()
            if service.sortField == field {
                service.sortAscending.toggle()
            } else {
                service.sortField = field
                service.sortAscending = false
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer() }
                Text(title)
                    .font(.system(size: 11, weight: service.sortField == field ? .bold : .semibold))
                    .foregroundColor(service.sortField == field ? .primary : .secondary)

                if service.sortField == field {
                    Image(systemName: service.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                if alignment == .leading { Spacer() }
            }
        }
        .buttonStyle(.plain)
    }

    private func processRow(_ proc: ManagedProcessEntry) -> some View {
        HStack(spacing: 8) {
            // 1. Process Info & Category Icon
            HStack(spacing: 8) {
                processIconView(for: proc)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(proc.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(proc.isSuspended ? .secondary : .primary)

                        if proc.isSuspended {
                            Text("已暂停")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        } else if proc.cpuPercent > 80.0 {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }

                    if let args = proc.arguments, !args.isEmpty {
                        Text(args)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 2. PID
            Text(String(proc.pid))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .center)

            // 3. CPU %
            Text(proc.cpuDisplayString)
                .font(.system(size: 12, weight: proc.cpuPercent > 50 ? .bold : .regular, design: .monospaced))
                .foregroundColor(proc.cpuPercent > 80 ? .red : (proc.cpuPercent > 30 ? .orange : .primary))
                .frame(width: 75, alignment: .trailing)

            // 4. Memory
            Text(proc.memoryDisplayString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 85, alignment: .trailing)

            // 5. Action Buttons (Pause / Terminate)
            HStack(spacing: 6) {
                // Pause / Resume Toggle Button
                Button {
                    Haptics.levelChange()
                    _ = service.toggleSuspend(process: proc)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: proc.isSuspended ? "play.fill" : "pause.fill")
                            .font(.system(size: 9))
                        Text(proc.isSuspended ? "恢复" : "暂停")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(proc.isSuspended ? Color.green.opacity(0.15) : Color.orange.opacity(0.12))
                    .foregroundColor(proc.isSuspended ? .green : .orange)
                    .cornerRadius(Design.radiusS)
                }
                .buttonStyle(.plain)
                .help(proc.isSuspended ? "恢复进程执行 (SIGCONT)" : "临时冻结进程让出 CPU/内存 (SIGSTOP)")

                // Terminate Button
                Button {
                    Haptics.levelChange()
                    processPendingTermination = proc
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("强杀")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(Design.radiusS)
                }
                .buttonStyle(.plain)
                .help("终止此进程 (SIGKILL)")
            }
            .frame(width: 130, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(proc.isSuspended ? Color.secondary.opacity(0.04) : Color.clear)
    }

    private func executeTermination(for proc: ManagedProcessEntry) {
        Task {
            isTerminating = true
            let res = await service.terminateProcess(process: proc, force: true)
            isTerminating = false
            processPendingTermination = nil
            if case .failure(let err) = res {
                terminationErrorMessage = err.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func processIconView(for proc: ManagedProcessEntry) -> some View {
        if let runningApp = NSRunningApplication(processIdentifier: proc.pid),
           let appIcon = runningApp.icon {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .cornerRadius(4.5)
                .opacity(proc.isSuspended ? 0.45 : 1.0)
        } else {
            // Elegant micro-tile card for command-line / background processes
            ZStack {
                RoundedRectangle(cornerRadius: 4.5)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                    )

                Image(systemName: proc.category.iconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(proc.isSuspended ? .secondary.opacity(0.4) : .secondary)
            }
            .frame(width: 20, height: 20)
            .opacity(proc.isSuspended ? 0.45 : 1.0)
        }
    }
}
