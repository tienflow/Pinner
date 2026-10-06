import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

// MARK: - Event Tap Helper

private protocol InputEventReceiver: AnyObject {
    func handleEvent(type: CGEventType, event: CGEvent)
}

private final class InputTapBridge: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var receiver: InputEventReceiver?
    private let lock = NSLock()

    private static let eventMask: CGEventMask = {
        let keyboard = (1 << CGEventType.keyDown.rawValue) |
                       (1 << CGEventType.flagsChanged.rawValue)
        let mouse = (1 << CGEventType.leftMouseDown.rawValue) |
                    (1 << CGEventType.rightMouseDown.rawValue) |
                    (1 << CGEventType.otherMouseDown.rawValue) |
                    (1 << CGEventType.mouseMoved.rawValue) |
                    (1 << CGEventType.leftMouseDragged.rawValue) |
                    (1 << CGEventType.rightMouseDragged.rawValue) |
                    (1 << CGEventType.scrollWheel.rawValue)
        return CGEventMask(keyboard | mouse)
    }()

    func start(receiver: InputEventReceiver) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tap != nil { return true }
        self.receiver = receiver

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let bridge = Unmanaged<InputTapBridge>.fromOpaque(refcon).takeUnretainedValue()
            bridge.process(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: context
        ) else {
            return false
        }

        self.tap = tapPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tapPort, enable: true)
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        receiver = nil
    }

    private func process(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        receiver?.handleEvent(type: type, event: event)
    }
}

// MARK: - Input Stats Service

@MainActor
public final class InputStatsService: ObservableObject, InputEventReceiver {
    public static let shared = InputStatsService()

    @Published public private(set) var stats: DailyInputStats
    @Published public private(set) var history: [String: DailyInputSummary] = [:]
    @Published public private(set) var currentKPS: Double = 0.0
    @Published public private(set) var currentCPS: Double = 0.0
    @Published public private(set) var currentAPM: Double = 0.0
    @Published public private(set) var isMonitoring: Bool = false
    @Published public private(set) var hasAccessibilityPermission: Bool = false

    private let bridge = InputTapBridge()
    private var saveTimer: Timer?
    private var decayTimer: Timer?
    private var isDirty = false

    // Sliding window for rate calculation
    private var keyTimestamps: [TimeInterval] = []
    private var clickTimestamps: [TimeInterval] = []

    // Mouse movement sampling
    private var lastMousePoint: CGPoint?
    private var lastMouseSampleTime: TimeInterval = 0
    private let mouseSampleInterval: TimeInterval = 1.0 / 30.0 // 30Hz
    private let pointsToMetersFactor: Double = 0.000352778    // ~1 pt ≈ 1/72 inch

    // Modifier state tracker
    private var lastModifierFlags: CGEventFlags = []
    private var pendingModifierName: String? = nil

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.tienyeung.Pinner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("input_stats.json")
    }()

    private let historyURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.tienyeung.Pinner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("input_stats_history.json")
    }()

    public init() {
        let today = DailyInputStats.todayDateString()
        let loaded = Self.loadFromDisk(url: storageURL)
        let loadedHistory = Self.loadHistoryFromDisk(url: historyURL) ?? [:]
        var hist = loadedHistory

        if let loaded = loaded {
            if loaded.dateString == today {
                self.stats = loaded
            } else {
                if !loaded.dateString.isEmpty {
                    hist[loaded.dateString] = DailyInputSummary(from: loaded)
                    Self.saveHistoryToDisk(hist, url: historyURL)
                }
                self.stats = DailyInputStats(dateString: today)
            }
        } else {
            self.stats = DailyInputStats(dateString: today)
        }
        Self.normalizeKeyFrequencies(&self.stats.keyFrequencies)
        self.history = hist
        checkPermission()
        startDecayTimer()
    }

    private static func normalizeKeyFrequencies(_ freqs: inout [String: Int]) {
        let legacyMap: [String: String] = [
            "⌘ Command": "Command ⌘",
            "⇧ Shift": "Shift ⇧",
            "⌥ Option": "Option ⌥",
            "⌃ Control": "Control ⌃",
            "Fn / 🌐": "Fn 🌐"
        ]
        for (legacy, modern) in legacyMap {
            if let count = freqs.removeValue(forKey: legacy) {
                freqs[modern, default: 0] += count
            }
        }
    }

    // MARK: - Permission & Monitoring

    public func checkPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted
        if trusted {
            startMonitoring()
        }
        return trusted
    }

    public func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func startMonitoring() {
        checkPermission()
        guard hasAccessibilityPermission else {
            isMonitoring = false
            return
        }
        if isMonitoring { return }
        let ok = bridge.start(receiver: self)
        isMonitoring = ok
        if ok {
            startSaveTimer()
        }
    }

    public func stopMonitoring() {
        bridge.stop()
        isMonitoring = false
        saveTimer?.invalidate()
        saveTimer = nil
        flushPendingSave()
    }

    // MARK: - Reset

    public func resetToday() {
        let today = DailyInputStats.todayDateString()
        stats = DailyInputStats(dateString: today)
        currentKPS = 0
        currentCPS = 0
        currentAPM = 0
        keyTimestamps.removeAll()
        clickTimestamps.removeAll()
        isDirty = true
        flushPendingSave()
    }

    // MARK: - Event Handling

    nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        Task { @MainActor in
            self.processEvent(type: type, event: event)
        }
    }

    private func checkDateRollover() {
        let today = DailyInputStats.todayDateString()
        if stats.dateString != today {
            if !stats.dateString.isEmpty {
                history[stats.dateString] = DailyInputSummary(from: stats)
                saveHistory()
            }
            flushPendingSave()
            stats = DailyInputStats(dateString: today)
            keyTimestamps.removeAll()
            clickTimestamps.removeAll()
            currentKPS = 0
            currentCPS = 0
            currentAPM = 0
        }
    }

    private func currentHour() -> Int {
        let hour = Calendar.current.component(.hour, from: Date())
        return min(max(hour, 0), 23)
    }

    private func activeAppInfo() -> (bundleId: String, name: String) {
        if let app = NSWorkspace.shared.frontmostApplication {
            let bundle = app.bundleIdentifier ?? "unknown"
            let name = app.localizedName ?? bundle
            return (bundle, name)
        }
        return ("unknown", "未知应用")
    }

    private func recordAppActivity(isKey: Bool = false, isClick: Bool = false, scrollPixels: Double = 0.0) {
        let (bundleId, appName) = activeAppInfo()
        let key = bundleId.isEmpty ? appName : bundleId
        var appStat = stats.appStats[key] ?? AppInputStats(bundleId: bundleId, appName: appName)
        if isKey {
            appStat.keyCount += 1
        }
        if isClick {
            appStat.clickCount += 1
        }
        if scrollPixels > 0 {
            appStat.scrollDistancePixels += scrollPixels
        }
        stats.appStats[key] = appStat
    }

    private func processEvent(type: CGEventType, event: CGEvent) {
        checkDateRollover()
        let now = ProcessInfo.processInfo.systemUptime
        let hour = currentHour()

        switch type {
        case .keyDown:
            // Consumed pending modifier when part of a shortcut combo
            pendingModifierName = nil

            stats.keyCount += 1
            stats.hourlyBuckets[hour].keyCount += 1
            keyTimestamps.append(now)
            recordAppActivity(isKey: true)

            // Track top key / shortcut
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let keyName = formatKeyName(keyCode: keyCode, flags: flags)
            if !keyName.isEmpty {
                stats.keyFrequencies[keyName, default: 0] += 1
            }
            isDirty = true

        case .flagsChanged:
            let flags = event.flags
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isDown = isModifierDown(keyCode: keyCode, flags: flags, previousFlags: lastModifierFlags)
            lastModifierFlags = flags

            if isDown {
                // Buffer modifier key; if followed by another key (shortcut combo), it will be consumed
                let name = modifierKeyName(keyCode: keyCode)
                if !name.isEmpty {
                    pendingModifierName = name
                }
            } else {
                // Modifier released. If not consumed by a key combo, count as a standalone modifier press
                if let name = pendingModifierName {
                    stats.keyCount += 1
                    stats.hourlyBuckets[hour].keyCount += 1
                    keyTimestamps.append(now)
                    recordAppActivity(isKey: true)
                    stats.keyFrequencies[name, default: 0] += 1
                    pendingModifierName = nil
                    isDirty = true
                }
            }

        case .leftMouseDown:
            stats.leftClickCount += 1
            stats.hourlyBuckets[hour].clickCount += 1
            clickTimestamps.append(now)
            recordAppActivity(isClick: true)
            isDirty = true

        case .rightMouseDown:
            stats.rightClickCount += 1
            stats.hourlyBuckets[hour].clickCount += 1
            clickTimestamps.append(now)
            recordAppActivity(isClick: true)
            isDirty = true

        case .otherMouseDown:
            let btnNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if btnNumber == 2 {
                stats.middleClickCount += 1
            } else {
                stats.otherClickCount += 1
            }
            stats.hourlyBuckets[hour].clickCount += 1
            clickTimestamps.append(now)
            recordAppActivity(isClick: true)
            isDirty = true

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if now - lastMouseSampleTime >= mouseSampleInterval {
                let currentPoint = event.location
                if let lastPoint = lastMousePoint {
                    let dx = currentPoint.x - lastPoint.x
                    let dy = currentPoint.y - lastPoint.y
                    let distPoints = sqrt(dx * dx + dy * dy)
                    if distPoints > 0 && distPoints < 5000 { // filter teleports
                        let meters = distPoints * pointsToMetersFactor
                        stats.mouseDistanceMeters += meters
                        stats.hourlyBuckets[hour].distanceMeters += meters
                        isDirty = true
                    }
                }
                lastMousePoint = currentPoint
                lastMouseSampleTime = now
            }

        case .scrollWheel:
            let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            let scrollPixels = (abs(deltaY) + abs(deltaX)) * 10.0
            if scrollPixels > 0 {
                stats.scrollDistancePixels += scrollPixels
                recordAppActivity(scrollPixels: scrollPixels)
                isDirty = true
            }

        default:
            break
        }
    }

    // MARK: - Speed Gauge Updates

    private func startDecayTimer() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRates()
            }
        }
    }

    private func updateRates() {
        let now = ProcessInfo.processInfo.systemUptime
        // 1.0 second sliding window for KPS & CPS
        keyTimestamps.removeAll { now - $0 > 1.0 }
        clickTimestamps.removeAll { now - $0 > 1.0 }

        currentKPS = Double(keyTimestamps.count)
        currentCPS = Double(clickTimestamps.count)

        if currentKPS > stats.peakKPS {
            stats.peakKPS = currentKPS
            isDirty = true
        }
        if currentCPS > stats.peakCPS {
            stats.peakCPS = currentCPS
            isDirty = true
        }

        // APM = (keys + clicks) in 1-second window * 60
        currentAPM = (currentKPS + currentCPS) * 60.0
    }

    // MARK: - Key Names & Helpers

    private func isModifierDown(keyCode: UInt16, flags: CGEventFlags, previousFlags: CGEventFlags) -> Bool {
        switch keyCode {
        case 55, 54: return flags.contains(.maskCommand) && !previousFlags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift) && !previousFlags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate) && !previousFlags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl) && !previousFlags.contains(.maskControl)
        case 63, 179: return flags.contains(.maskSecondaryFn) && !previousFlags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    private func modifierKeyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 55, 54: return "Command ⌘"
        case 56, 60: return "Shift ⇧"
        case 58, 61: return "Option ⌥"
        case 59, 62: return "Control ⌃"
        case 63, 179: return "Fn 🌐"
        default: return ""
        }
    }

    private func formatKeyName(keyCode: UInt16, flags: CGEventFlags) -> String {
        let base = baseKeyName(keyCode: keyCode)
        guard !base.isEmpty else { return "" }

        var prefix = ""
        if flags.contains(.maskControl) { prefix += "⌃" }
        if flags.contains(.maskAlternate) { prefix += "⌥" }
        let hasOtherModifier = flags.contains(.maskControl) || flags.contains(.maskAlternate) || flags.contains(.maskCommand)
        if flags.contains(.maskShift) && (base.count > 1 || hasOtherModifier) { prefix += "⇧" }
        if flags.contains(.maskCommand) { prefix += "⌘" }

        return prefix.isEmpty ? base : "\(prefix)\(base)"
    }

    private func baseKeyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return ⏎"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab ⇥"
        case 49: return "Space 空格"
        case 50: return "`"
        case 51: return "Delete ⌫"
        case 53: return "Esc ⎋"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "ForwardDelete ⌦"
        case 119: return "End"
        case 121: return "PageDown"
        case 123: return "Left ←"
        case 124: return "Right →"
        case 125: return "Down ↓"
        case 126: return "Up ↑"
        default: return ""
        }
    }

    // MARK: - Persistence

    private func startSaveTimer() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushPendingSave()
            }
        }
    }

    public func flushPendingSave() {
        guard isDirty else { return }
        isDirty = false
        do {
            let data = try JSONEncoder().encode(stats)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[InputStatsService] save failed: \(error)")
        }
    }

    private static func loadFromDisk(url: URL) -> DailyInputStats? {
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(DailyInputStats.self, from: data) else {
            return nil
        }
        return stats
    }

    // MARK: - History Persistence & Query

    public func historySeries(days: Int) -> [DailyInputSummary] {
        let calendar = Calendar.current
        let today = Date()
        let todayString = DailyInputStats.todayDateString()
        let count = max(days, 1)
        var result: [DailyInputSummary] = []
        result.reserveCapacity(count)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let targetDate = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dString = formatter.string(from: targetDate)
            if dString == todayString {
                result.append(DailyInputSummary(from: stats))
            } else if let archived = history[dString] {
                result.append(archived)
            } else {
                result.append(DailyInputSummary(dateString: dString))
            }
        }
        return result
    }

    public func recordHistoryDay(_ summary: DailyInputSummary) {
        history[summary.dateString] = summary
        saveHistory()
    }

    public func removeHistoryDay(_ dateString: String) {
        history.removeValue(forKey: dateString)
        saveHistory()
    }

    public func aggregatedAppStats(range: AppStatsRange) -> [AppInputStats] {
        var aggregated: [String: AppInputStats] = [:]

        func merge(_ dict: [String: AppInputStats]) {
            for (key, stat) in dict {
                if var existing = aggregated[key] {
                    existing.keyCount += stat.keyCount
                    existing.clickCount += stat.clickCount
                    existing.scrollDistancePixels += stat.scrollDistancePixels
                    aggregated[key] = existing
                } else {
                    aggregated[key] = stat
                }
            }
        }

        // Today's live stats
        merge(stats.appStats)

        if range == .today {
            return Array(aggregated.values)
        }

        let days: Int
        switch range {
        case .today: days = 1
        case .days7: days = 7
        case .days30: days = 30
        case .all: days = 365
        }

        let series = historySeries(days: days)
        for item in series where item.dateString != stats.dateString {
            merge(item.appStats)
        }

        return Array(aggregated.values)
    }

    public func saveHistory() {
        Self.saveHistoryToDisk(history, url: historyURL)
    }

    private static func saveHistoryToDisk(_ history: [String: DailyInputSummary], url: URL) {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[InputStatsService] save history failed: \(error)")
        }
    }

    private static func loadHistoryFromDisk(url: URL) -> [String: DailyInputSummary]? {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([String: DailyInputSummary].self, from: data) else {
            return nil
        }
        return history
    }
}
