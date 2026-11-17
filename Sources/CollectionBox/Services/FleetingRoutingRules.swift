import Foundation

/// One user-defined fleeting routing rule for an Apple Notes folder.
/// Stored locally in `Application Support/Pinner/fleeting-routing-rules.json`
/// so personal folder names and keywords stay out of the open-source codebase.
public struct FleetingFolderRule: Codable, Sendable, Equatable {
    public var folder: String
    public var description: String
    public var keywords: [String]

    public init(folder: String, description: String = "", keywords: [String] = []) {
        self.folder = folder
        self.description = description
        self.keywords = keywords
    }
}

struct FleetingRoutingRulesFile: Codable, Sendable {
    var version: Int
    var folders: [FleetingFolderRule]
    var logKeywords: [String]
}

/// Immutable snapshot of optional user-defined fleeting capture routing rules.
public struct FleetingRoutingRulesTable: Sendable {
    public static let empty = FleetingRoutingRulesTable(orderedRules: [], logKeywords: [])

    public let orderedRules: [FleetingFolderRule]
    public let rulesByFolder: [String: FleetingFolderRule]
    public let logKeywords: [String]

    public init(orderedRules: [FleetingFolderRule], logKeywords: [String] = []) {
        self.orderedRules = orderedRules
        var map: [String: FleetingFolderRule] = [:]
        for rule in orderedRules {
            let key = rule.folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty {
                map[key] = rule
            }
        }
        self.rulesByFolder = map
        self.logKeywords = logKeywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func description(for folder: String) -> String? {
        let key = folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let desc = rulesByFolder[key]?.description.trimmingCharacters(in: .whitespacesAndNewlines),
              !desc.isEmpty else {
            return nil
        }
        return desc
    }

    public func matchesKeywords(folder: String, input: String) -> Bool {
        let key = folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let keywords = rulesByFolder[key]?.keywords, !keywords.isEmpty else { return false }
        let lowerInput = input.lowercased()
        return keywords.contains { kw in
            let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !trimmed.isEmpty && lowerInput.contains(trimmed)
        }
    }

    public func matchingRuleFolder(for input: String, in folderTree: [AppleNotesService.FolderItem]) -> String? {
        let lowerInput = input.lowercased()
        let availableByLower = Dictionary(
            folderTree.map { ($0.name.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        for rule in orderedRules {
            let key = rule.folder.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let targetName = availableByLower[key] else { continue }
            if rule.keywords.contains(where: { kw in
                let trimmed = kw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !trimmed.isEmpty && lowerInput.contains(trimmed)
            }) {
                return targetName
            }
        }
        return nil
    }

    public func isLogInput(_ input: String) -> Bool {
        if input.contains("打卡") || input.contains("日志") {
            return true
        }
        if input.range(of: #"第\s*\d+\s*天"#, options: .regularExpression) != nil {
            return true
        }
        let lower = input.lowercased()
        return logKeywords.contains { lower.contains($0.lowercased()) }
    }

    /// Generic overlap check between user input and a folder's existing note titles.
    public static func noteTitleOverlaps(_ input: String, notes: [String]) -> Bool {
        overlapScore(input: input, notes: notes) >= 2
    }

    /// Picks the folder whose name or existing note titles best match the input.
    public static func bestMatchingFolder(
        for input: String,
        in folderTree: [AppleNotesService.FolderItem]
    ) -> String? {
        let lowerInput = input.lowercased()
        var bestFolder: String?
        var bestScore = 0

        for item in folderTree {
            if item.name == "Recently Deleted" || item.name == "最近删除" { continue }
            var score = 0
            let folderLower = item.name.lowercased()
            if !folderLower.isEmpty && lowerInput.contains(folderLower) {
                score += 10
            }
            score += overlapScore(input: input, notes: item.notes)
            if score > bestScore {
                bestScore = score
                bestFolder = item.name
            }
        }

        return bestScore >= 2 ? bestFolder : nil
    }

    private static func overlapScore(input: String, notes: [String]) -> Int {
        let lowerInput = input.lowercased()
        let trimChars = CharacterSet(charactersIn: "【】[]()《》「」『』 ").union(.whitespacesAndNewlines)
        var maxScore = 0

        for note in notes.prefix(20) {
            let cleaned = note.trimmingCharacters(in: trimChars).lowercased()
            guard cleaned.count >= 2 else { continue }

            if lowerInput.contains(cleaned) {
                maxScore = max(maxScore, 8)
                continue
            }

            let chars = Array(cleaned)
            guard chars.count >= 2 else { continue }
            var hits = 0
            var matchedBigrams = Set<String>()
            for i in 0..<(chars.count - 1) {
                let bigram = String([chars[i], chars[i + 1]])
                if bigram.trimmingCharacters(in: .whitespacesAndNewlines).count == 2,
                   !matchedBigrams.contains(bigram),
                   lowerInput.contains(bigram) {
                    matchedBigrams.insert(bigram)
                    hits += 2
                }
            }
            maxScore = max(maxScore, hits)
        }
        return maxScore
    }
}

/// Loads optional per-user fleeting routing rules from `Application Support/Pinner`.
public final class FleetingRoutingRulesService: @unchecked Sendable {
    public static let shared = FleetingRoutingRulesService()

    private let fileURL: URL
    private let lock = NSLock()
    private var cachedTable: FleetingRoutingRulesTable = .empty

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        reload()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pinner/fleeting-routing-rules.json")
    }

    public var table: FleetingRoutingRulesTable {
        lock.lock()
        defer { lock.unlock() }
        return cachedTable
    }

    public func reload() {
        let loaded: FleetingRoutingRulesTable
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(FleetingRoutingRulesFile.self, from: data) {
            loaded = FleetingRoutingRulesTable(
                orderedRules: decoded.folders,
                logKeywords: decoded.logKeywords
            )
        } else {
            loaded = .empty
        }
        lock.lock()
        cachedTable = loaded
        lock.unlock()
    }
}
