import SwiftUI
import AppKit

public struct PortManagerView: View {
    @ObservedObject private var service: PortManagerService
    var onClose: () -> Void

    @State private var selectedProcessForDetail: PortProcessInfo? = nil
    @State private var processPendingTermination: PortProcessInfo? = nil
    @State private var isTerminating: Bool = false
    @State private var terminationErrorMessage: String? = nil
    @State private var sortField: PortTableSortField = .port
    @State private var sortAscending: Bool = true

    public init(service: PortManagerService = .shared, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerBar
                Divider().opacity(0.15)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        // 1. Overview 4-Metric Cards Grid
                        overviewCardsGrid

                        // 2. Search & Filter Bar
                        searchAndFilterBar

                        // 3. Summary Count Bar
                        summaryCountBar

                        // 4. Process Table List
                        processTableSection
                    }
                    .padding(16)
                }

                Divider().opacity(0.15)
                bottomBar
            }

            // Detail Sheet Overlay
            if let detailProc = selectedProcessForDetail {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        selectedProcessForDetail = nil
                    }

                PortProcessDetailView(process: detailProc, service: service) {
                    selectedProcessForDetail = nil
                }
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .frame(width: 680, height: 600)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .confirmationDialog(
            "终止进程",
            isPresented: Binding(
                get: { processPendingTermination != nil },
                set: { if !$0 { processPendingTermination = nil } }
            ),
            presenting: processPendingTermination
        ) { proc in
            Button(
                proc.category == .docker ? "停止 Docker 容器 \(proc.displayName)" : (proc.isRoot ? "授权管理员权限终止 PID \(proc.pid)" : "强制终止 PID \(proc.pid)"),
                role: .destructive
            ) {
                executeTermination(for: proc)
            }
            Button("取消", role: .cancel) {
                processPendingTermination = nil
            }
        } message: { proc in
            if proc.category == .docker {
                Text("确定要停止 Docker 容器 \(proc.displayName) (端口: \(proc.portsDisplayString)) 吗？\n停止容器将释放该端口，容器状态将转为 Exited。")
            } else {
                Text("确定要终止 \(proc.displayName) (端口: \(proc.portsDisplayString)) 吗？\n\(proc.isRoot ? "⚠️ 此进程由 root 用户运行，需要系统管理员授权。" : "未保存的工作可能会丢失。")")
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)

            Text("端口管家")
                .font(.system(size: 14, weight: .bold))

            // Status Indicator Dot
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)

                Text("实时监控")
                    .font(.system(size: Design.micro, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.12))
            .cornerRadius(Design.radiusS)

            Spacer()

            // Refresh Button
            PanelRefreshButton(isLoading: service.isLoading, helpText: "立即刷新端口列表") {
                Task {
                    await service.refresh()
                }
            }

            // Close Button
            PanelCloseButton(helpText: "关闭面板 (⎋)") {
                onClose()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Overview Cards Grid (4 Cards)

    private var overviewCardsGrid: some View {
        HStack(spacing: 10) {
            // Card 1: 监听端口
            overviewCard(
                title: "监听端口",
                value: "\(service.stats.activePortCount) 个",
                sub: "分布于 \(service.processes.count) 个服务",
                icon: "waveform.path.ecg",
                color: .blue
            )

            // Card 2: 进程内存
            overviewCard(
                title: "总内存占用",
                value: service.stats.memoryDisplayString,
                sub: "监听进程常驻内存",
                icon: "memorychip",
                color: .green
            )

            // Card 3: CPU 占用
            overviewCard(
                title: "总 CPU 占用",
                value: service.stats.cpuDisplayString,
                sub: "所有监听服务总计",
                icon: "cpu",
                color: .orange
            )

            // Card 4: 外部暴露 (点击可一键筛选只看外部暴露端口)
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.15)) {
                    if service.selectedFilter == .exposed {
                        service.selectedFilter = .all
                    } else {
                        service.selectedFilter = .exposed
                    }
                }
            } label: {
                overviewCard(
                    title: "外部暴露",
                    value: "\(service.stats.exposedPortCount) 个",
                    sub: service.selectedFilter == .exposed
                        ? "已筛选显示 · 点击还原"
                        : (service.stats.exposedPortCount > 0 ? "绑定 0.0.0.0 / 点击筛选" : "全为本机回环隔离"),
                    icon: service.stats.exposedPortCount > 0 ? "globe" : "lock.shield",
                    color: service.stats.exposedPortCount > 0 ? .teal : .green,
                    isSelected: service.selectedFilter == .exposed
                )
            }
            .buttonStyle(.plain)
            .help(service.selectedFilter == .exposed ? "点击取消筛选，查看全部端口" : "点击一键筛选外部暴露（局域网可访问）的端口")
        }
    }

    private func overviewCard(
        title: String,
        value: String,
        sub: String,
        icon: String,
        color: Color,
        isSelected: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: Design.caption, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text(sub)
                .font(.system(size: Design.micro))
                .foregroundColor(isSelected ? color : .secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? color.opacity(0.12) : Color.primary.opacity(Design.hoverAlpha))
        .cornerRadius(Design.radiusM)
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .strokeBorder(isSelected ? color : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: - Search & Filter Bar

    private var searchAndFilterBar: some View {
        HStack(spacing: 10) {
            // Search Input
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("搜索进程名、PID 或端口 (如 :3000)...", text: $service.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: Design.ui))

                if !service.searchText.isEmpty {
                    Button {
                        service.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(Design.slotAlpha))
            .cornerRadius(Design.radiusS)

            // Category Filter Picker
            HStack(spacing: 2) {
                ForEach(ProcessFilterCategory.allCases) { cat in
                    let isSelected = service.selectedFilter == cat
                    Button {
                        service.selectedFilter = cat
                    } label: {
                        Text(cat.rawValue)
                            .font(.system(size: Design.micro, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(Design.slotAlpha))
            .cornerRadius(6)
        }
    }

    // MARK: - Summary Count Bar

    @ViewBuilder
    private var summaryCountBar: some View {
        if service.selectedFilter != .all || !service.searchText.isEmpty {
            HStack {
                Spacer()
                Text("当前显示 \(sortedAndFilteredProcesses.count) 项")
                    .font(.system(size: Design.micro, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Process Table Section

    private var filteredProcesses: [PortProcessInfo] {
        let query = service.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return service.processes.filter { proc in
            // 1. Category Filter
            switch service.selectedFilter {
            case .all: break
            case .exposed: if !proc.isExposed { return false }
            case .dev: if proc.category != .devServer { return false }
            case .docker: if proc.category != .docker { return false }
            case .user: if proc.category != .userApp { return false }
            case .system: if proc.category != .systemDaemon { return false }
            }

            // 2. Search Text
            if query.isEmpty { return true }

            let cleanQuery = query.hasPrefix(":") ? String(query.dropFirst()) : query

            // Match PID
            if String(proc.pid).contains(cleanQuery) { return true }

            // Match Port
            if proc.ports.contains(where: { String($0).contains(cleanQuery) }) { return true }

            // Match Command or Display Name
            if proc.displayName.lowercased().contains(cleanQuery) { return true }

            // Match Path
            if proc.fullPath.lowercased().contains(cleanQuery) { return true }

            return false
        }
    }

    private var sortedAndFilteredProcesses: [PortProcessInfo] {
        let list = filteredProcesses
        return list.sorted { a, b in
            let isAscending: Bool
            switch sortField {
            case .name:
                isAscending = a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .pid:
                isAscending = a.pid < b.pid
            case .port:
                let aPort = a.ports.first ?? Int.max
                let bPort = b.ports.first ?? Int.max
                isAscending = aPort < bPort
            case .category:
                isAscending = a.category.rawValue.localizedStandardCompare(b.category.rawValue) == .orderedAscending
            case .cpu:
                isAscending = a.cpuPercent < b.cpuPercent
            case .memory:
                isAscending = a.memoryBytes < b.memoryBytes
            }
            return sortAscending ? isAscending : !isAscending
        }
    }

    private var processTableSection: some View {
        VStack(spacing: 0) {
            // Table Header
            tableHeaderRow

            Divider().opacity(0.12)

            let list = sortedAndFilteredProcesses
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text(service.searchText.isEmpty ? "未发现匹配的监听进程" : "无符合搜索条件的端口进程")
                        .font(.system(size: Design.ui))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(list) { proc in
                        processRow(proc)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.03))
        .cornerRadius(Design.radiusM)
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusM)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 8) {
            sortableHeader(title: "进程名称", field: .name, width: 160, alignment: .leading)
            sortableHeader(title: "PID", field: .pid, width: 50, alignment: .leading)
            sortableHeader(title: "监听端口", field: .port, width: 135, alignment: .leading)
            sortableHeader(title: "分类", field: .category, width: 64, alignment: .leading)
            sortableHeader(title: "CPU", field: .cpu, width: 50, alignment: .trailing)
            sortableHeader(title: "内存", field: .memory, width: 65, alignment: .trailing)

            Spacer()

            Text("操作")
                .font(.system(size: Design.micro, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sortableHeader(title: String, field: PortTableSortField, width: CGFloat, alignment: Alignment) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = (field == .cpu || field == .memory) ? false : true
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.system(size: Design.micro, weight: sortField == field ? .semibold : .medium))
                    .foregroundColor(sortField == field ? .primary : .secondary)

                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                if alignment == .leading {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)\(sortField == field ? (sortAscending ? "降序" : "升序") : "排序")")
    }

    private func processRow(_ proc: PortProcessInfo) -> some View {
        HStack(spacing: 8) {
            // 1. Process Icon + Name + User/Root badge
            HStack(spacing: 6) {
                appIcon(for: proc)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(proc.displayName)
                            .font(.system(size: Design.ui, weight: .medium))
                            .lineLimit(1)

                        if proc.isRoot {
                            Text("root")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 0.5)
                                .background(Color.orange.opacity(0.15))
                                .cornerRadius(2)
                        }
                    }

                    Text(proc.category == .docker ? (proc.containerImage ?? "docker") : (proc.user.isEmpty ? "system" : proc.user))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 160, alignment: .leading)

            // 2. PID
            Text("\(proc.pid)")
                .font(.system(size: Design.ui, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            // 3. Ports & Network Exposure Badge
            HStack(spacing: 4) {
                Text(proc.ports.first.map(String.init) ?? "--")
                    .font(.system(size: Design.ui, weight: .bold, design: .monospaced))
                    .foregroundColor(proc.category == .devServer ? .blue : .primary)

                Text(proc.protocolType)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)

                if proc.ports.count > 1 {
                    Text("+\(proc.ports.count - 1)")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 2)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(2)
                }

                // Exposure indicator badge (局域网 vs 本机)
                if proc.isExposed {
                    HStack(spacing: 2) {
                        Image(systemName: "globe")
                            .font(.system(size: 7))
                        Text("局域网")
                            .font(.system(size: 7.5, weight: .semibold))
                    }
                    .foregroundColor(.teal)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Color.teal.opacity(0.14))
                    .cornerRadius(3)
                    .help("此服务绑定 0.0.0.0/*，局域网/公网可直接访问")
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 6.5))
                        Text("本机")
                            .font(.system(size: 7.5, weight: .medium))
                    }
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(3)
                    .help("此服务绑定 127.0.0.1，仅限本机访问")
                }
            }
            .frame(width: 135, alignment: .leading)

            // 4. Category
            HStack(spacing: 3) {
                Image(systemName: proc.category.icon)
                    .font(.system(size: 8))
                Text(proc.category.rawValue)
                    .font(.system(size: 9))
            }
            .foregroundColor(badgeColor(for: proc.category))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(badgeColor(for: proc.category).opacity(0.12))
            .cornerRadius(3)
            .frame(width: 64, alignment: .leading)

            // 5. CPU
            Text(String(format: "%.1f%%", proc.cpuPercent))
                .font(.system(size: Design.caption, design: .monospaced))
                .foregroundColor(proc.cpuPercent > 30 ? .orange : .secondary)
                .frame(width: 50, alignment: .trailing)

            // 6. Memory
            Text(proc.memoryDisplayString)
                .font(.system(size: Design.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 65, alignment: .trailing)

            Spacer()

            // 7. Actions: Detail (Waveform) + Terminate (Power)
            HStack(spacing: 8) {
                // Detail Button
                Button {
                    selectedProcessForDetail = proc
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("查看进程详情")

                // Terminate Button
                Button {
                    processPendingTermination = proc
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(width: 22, height: 22)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("终止此进程")
            }
            .frame(width: 60, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func badgeColor(for cat: ProcessCategory) -> Color {
        switch cat {
        case .devServer: return .blue
        case .docker: return .teal
        case .userApp: return .purple
        case .systemDaemon: return .secondary
        }
    }

    private func appIcon(for proc: PortProcessInfo) -> some View {
        if proc.category == .docker {
            return AnyView(
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.teal)
                    .frame(width: 18, height: 18)
                    .background(Color.teal.opacity(0.15))
                    .cornerRadius(4)
            )
        }

        let path = proc.fullPath
        let icon: NSImage
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage()
        }
        return AnyView(
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .cornerRadius(4)
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if let err = terminationErrorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    Text(err)
                        .font(.system(size: Design.micro))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            if let updated = service.lastUpdated {
                Text("更新于 \(formattedTime(updated))")
                    .font(.system(size: Design.micro))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func formattedTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: date)
    }

    private func executeTermination(for proc: PortProcessInfo) {
        processPendingTermination = nil
        isTerminating = true
        terminationErrorMessage = nil

        Task {
            let res = await service.terminateProcess(process: proc, force: true)
            isTerminating = false
            switch res {
            case .success:
                terminationErrorMessage = nil
            case .failure(let err):
                terminationErrorMessage = err.localizedDescription
            }
        }
    }
}
