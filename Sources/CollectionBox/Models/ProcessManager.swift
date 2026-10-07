import Foundation
import AppKit

public enum ManagedProcessCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case devTool = "开发工具"
    case runtime = "运行环境"
    case docker = "Docker"
    case userApp = "应用程序"
    case system = "系统后台"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .devTool: return "hammer.fill"
        case .runtime: return "terminal.fill"
        case .docker: return "shippingbox.fill"
        case .userApp: return "macwindow"
        case .system: return "gearshape.fill"
        }
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal = "正常"
    case warning = "轻度受压"
    case critical = "严重告警"

    public var colorName: String {
        switch self {
        case .normal: return "green"
        case .warning: return "orange"
        case .critical: return "red"
        }
    }
}

public struct SystemPressureInfo: Sendable, Equatable {
    public var cpuUserPercent: Double = 0.0
    public var cpuSystemPercent: Double = 0.0
    public var cpuTotalPercent: Double = 0.0
    public var logicalCores: Int = ProcessInfo.processInfo.processorCount

    public var memoryPressure: MemoryPressureLevel = .normal
    public var physicalMemoryUsedBytes: UInt64 = 0
    public var physicalMemoryTotalBytes: UInt64 = 0

    public var swapUsedBytes: UInt64 = 0
    public var swapTotalBytes: UInt64 = 0

    public init(
        cpuUserPercent: Double = 0.0,
        cpuSystemPercent: Double = 0.0,
        cpuTotalPercent: Double = 0.0,
        logicalCores: Int = ProcessInfo.processInfo.processorCount,
        memoryPressure: MemoryPressureLevel = .normal,
        physicalMemoryUsedBytes: UInt64 = 0,
        physicalMemoryTotalBytes: UInt64 = 0,
        swapUsedBytes: UInt64 = 0,
        swapTotalBytes: UInt64 = 0
    ) {
        self.cpuUserPercent = cpuUserPercent
        self.cpuSystemPercent = cpuSystemPercent
        self.cpuTotalPercent = cpuTotalPercent
        self.logicalCores = logicalCores
        self.memoryPressure = memoryPressure
        self.physicalMemoryUsedBytes = physicalMemoryUsedBytes
        self.physicalMemoryTotalBytes = physicalMemoryTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
    }

    public var memoryDisplayString: String {
        let usedGB = Double(physicalMemoryUsedBytes) / 1_073_741_824.0
        let totalGB = Double(physicalMemoryTotalBytes) / 1_073_741_824.0
        return String(format: "%.1f GB / %.0f GB", usedGB, totalGB)
    }

    public var swapDisplayString: String {
        if swapUsedBytes == 0 { return "0 MB" }
        let mb = Double(swapUsedBytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
    }
}

public struct ManagedProcessEntry: Identifiable, Sendable, Equatable {
    public let id: pid_t
    public let pid: pid_t
    public let name: String
    public let arguments: String?
    public let displayName: String
    public let fullPath: String
    public var cpuPercent: Double
    public var residentMemoryBytes: UInt64
    public var energyImpact: Double
    public var isSuspended: Bool
    public var isDocker: Bool
    public var dockerContainerName: String?
    public var category: ManagedProcessCategory

    public init(
        pid: pid_t,
        name: String,
        arguments: String? = nil,
        displayName: String? = nil,
        fullPath: String = "",
        cpuPercent: Double = 0.0,
        residentMemoryBytes: UInt64 = 0,
        energyImpact: Double = 0.0,
        isSuspended: Bool = false,
        isDocker: Bool = false,
        dockerContainerName: String? = nil,
        category: ManagedProcessCategory = .userApp
    ) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.arguments = arguments
        self.fullPath = fullPath
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.energyImpact = energyImpact
        self.isSuspended = isSuspended
        self.isDocker = isDocker
        self.dockerContainerName = dockerContainerName
        self.category = category

        if let explicitDisplay = displayName {
            self.displayName = explicitDisplay
        } else if let container = dockerContainerName {
            self.displayName = "Docker: \(container)"
        } else if let args = arguments, !args.isEmpty {
            self.displayName = "\(name) (\(args))"
        } else {
            self.displayName = name
        }
    }

    public var memoryDisplayString: String {
        let mb = Double(residentMemoryBytes) / 1_048_576.0
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        } else {
            return String(format: "%.0f MB", mb)
        }
    }

    public var cpuDisplayString: String {
        String(format: "%.1f%%", cpuPercent)
    }

    public var energyDisplayString: String {
        if energyImpact < 0.1 {
            return "0.0"
        }
        return String(format: "%.1f", energyImpact)
    }
}

public enum ProcessSortField: String, CaseIterable, Identifiable, Sendable {
    case cpu = "CPU"
    case memory = "内存"
    case energy = "功耗"
    case name = "名称"
    case pid = "PID"

    public var id: String { rawValue }
}

public enum ProcessFilterOption: String, CaseIterable, Identifiable, Sendable {
    case highLoad = "高负载"
    case activeApps = "活跃应用"
    case suspended = "已冻结"
    case all = "全部"

    public var id: String { rawValue }
}
