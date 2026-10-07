import Foundation
import AppKit

/// Category classification for a process listening on network ports.
public enum ProcessCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case devServer = "开发服务"
    case docker = "Docker"
    case userApp = "用户应用"
    case systemDaemon = "系统服务"

    public static let dockerContainer = ProcessCategory.docker

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .devServer: return "hammer.fill"
        case .docker: return "shippingbox.fill"
        case .userApp: return "app.fill"
        case .systemDaemon: return "gearshape.2.fill"
        }
    }
}

/// Filter options for UI list.
public enum ProcessFilterCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case dev = "开发服务"
    case docker = "Docker"
    case user = "用户应用"
    case system = "系统服务"
    case exposed = "外部暴露"

    public var id: String { rawValue }
}

/// Sorting field for process table.
public enum PortTableSortField: String, CaseIterable, Identifiable, Sendable {
    case name = "名称"
    case pid = "PID"
    case port = "端口"
    case category = "分类"
    case cpu = "CPU"
    case memory = "内存"

    public var id: String { rawValue }
}

/// Comprehensive information about a process listening on ports.
public struct PortProcessInfo: Identifiable, Hashable, Sendable {
    public var id: String {
        if let container = containerName {
            return "\(pid)_\(container)"
        }
        return "\(pid)"
    }
    public let pid: pid_t
    public let command: String
    public let fullPath: String
    public let commandLine: String
    public let user: String
    public let isRoot: Bool
    public let ports: [Int]
    public let protocolType: String
    public let cpuPercent: Double
    public let memoryBytes: Int64
    public let category: ProcessCategory
    public var isFavorite: Bool
    public let isExposed: Bool
    public let exposedPorts: [Int]
    public let containerName: String?
    public let containerImage: String?

    public init(
        pid: pid_t,
        command: String,
        fullPath: String = "",
        commandLine: String = "",
        user: String = "",
        isRoot: Bool = false,
        ports: [Int] = [],
        protocolType: String = "TCP",
        cpuPercent: Double = 0.0,
        memoryBytes: Int64 = 0,
        category: ProcessCategory = .userApp,
        isFavorite: Bool = false,
        isExposed: Bool = false,
        exposedPorts: [Int] = [],
        containerName: String? = nil,
        containerImage: String? = nil
    ) {
        self.pid = pid
        self.command = command
        self.fullPath = fullPath
        self.commandLine = commandLine
        self.user = user
        self.isRoot = isRoot
        self.ports = ports
        self.protocolType = protocolType
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.category = category
        self.isFavorite = isFavorite
        self.isExposed = isExposed
        self.exposedPorts = exposedPorts
        self.containerName = containerName
        self.containerImage = containerImage
    }

    /// Display title for the process (prefer container name, then command, then fullPath).
    public var displayName: String {
        if let container = containerName, !container.isEmpty {
            return container
        }
        if !command.isEmpty {
            return command
        }
        if !fullPath.isEmpty {
            return (fullPath as NSString).lastPathComponent
        }
        return "PID \(pid)"
    }

    /// Formatted ports string, e.g. "3000, 3001"
    public var portsDisplayString: String {
        ports.map(String.init).joined(separator: ", ")
    }

    /// Formatted memory string, e.g. "26 MB", "1.2 GB"
    public var memoryDisplayString: String {
        Self.formatBytes(memoryBytes)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.0f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.0f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }
}

/// Aggregated summary statistics for header overview cards.
public struct PortSummaryStats: Sendable, Equatable {
    public var activePortCount: Int
    public var totalMemoryBytes: Int64
    public var devServerCount: Int
    public var dockerCount: Int
    public var rootProcessCount: Int
    public var totalCpuPercent: Double
    public var exposedPortCount: Int

    public var dockerContainerCount: Int {
        get { dockerCount }
        set { dockerCount = newValue }
    }

    public init(
        activePortCount: Int = 0,
        totalMemoryBytes: Int64 = 0,
        devServerCount: Int = 0,
        dockerCount: Int = 0,
        rootProcessCount: Int = 0,
        totalCpuPercent: Double = 0.0,
        exposedPortCount: Int = 0
    ) {
        self.activePortCount = activePortCount
        self.totalMemoryBytes = totalMemoryBytes
        self.devServerCount = devServerCount
        self.dockerCount = dockerCount
        self.rootProcessCount = rootProcessCount
        self.totalCpuPercent = totalCpuPercent
        self.exposedPortCount = exposedPortCount
    }

    public init(
        activePortCount: Int = 0,
        totalMemoryBytes: Int64 = 0,
        devServerCount: Int = 0,
        dockerContainerCount: Int,
        rootProcessCount: Int = 0,
        totalCpuPercent: Double = 0.0,
        exposedPortCount: Int = 0
    ) {
        self.activePortCount = activePortCount
        self.totalMemoryBytes = totalMemoryBytes
        self.devServerCount = devServerCount
        self.dockerCount = dockerContainerCount
        self.rootProcessCount = rootProcessCount
        self.totalCpuPercent = totalCpuPercent
        self.exposedPortCount = exposedPortCount
    }

    public var memoryDisplayString: String {
        PortProcessInfo.formatBytes(totalMemoryBytes)
    }

    public var cpuDisplayString: String {
        String(format: "%.1f%%", totalCpuPercent)
    }
}
