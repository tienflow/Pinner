import Foundation
import SQLite3

struct SkillRecord: Sendable, Identifiable, Codable {
    var id: UUID = UUID()
    let agent: StatsAgent
    let skillName: String
    let tsMs: Int64
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case agent, skillName, tsMs, sessionId
    }

    init(agent: StatsAgent, skillName: String, tsMs: Int64, sessionId: String?) {
        self.id = UUID()
        self.agent = agent
        self.skillName = skillName
        self.tsMs = tsMs
        self.sessionId = sessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.agent = try container.decode(StatsAgent.self, forKey: .agent)
        self.skillName = try container.decode(String.self, forKey: .skillName)
        self.tsMs = try container.decode(Int64.self, forKey: .tsMs)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        try container.encode(skillName, forKey: .skillName)
        try container.encode(tsMs, forKey: .tsMs)
        try container.encode(sessionId, forKey: .sessionId)
    }
}

struct SkillRankRow: Identifiable, Sendable {
    var id: String { name }
    let rank: Int
    let name: String
    let count: Int
    let agents: [StatsAgent]
    let lastUsedMs: Int64?
    let share: Double
}

struct DiskSkillCacheEntry: Codable, Sendable {
    let mtime: TimeInterval
    let size: Int64
    let records: [SkillRecord]
}

final class SkillStatsService: @unchecked Sendable {
    static let shared = SkillStatsService()

    private let memoryLock = NSLock()
    private var cachedRecords: [SkillRecord]?
    private var cachedInstalled: Set<String>?
    private var lastScanAt: Date?

    private static let diskCacheLock = NSLock()
    private static var diskCacheMemoryMap: [String: DiskSkillCacheEntry]?

    static let cacheFileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let dir = base.appendingPathComponent("com.tienyeung.Pinner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skill_scan_cache.json")
    }()

    init() {}

    func clearCacheForTesting() {
        memoryLock.lock()
        cachedRecords = nil
        cachedInstalled = nil
        lastScanAt = nil
        memoryLock.unlock()

        Self.diskCacheLock.lock()
        Self.diskCacheMemoryMap = nil
        try? FileManager.default.removeItem(at: Self.cacheFileURL)
        Self.diskCacheLock.unlock()
    }

    private static func loadDiskCache() -> [String: DiskSkillCacheEntry] {
        diskCacheLock.lock()
        defer { diskCacheLock.unlock() }
        if let existing = diskCacheMemoryMap { return existing }
        guard let data = try? Data(contentsOf: cacheFileURL),
              let dict = try? JSONDecoder().decode([String: DiskSkillCacheEntry].self, from: data) else {
            diskCacheMemoryMap = [:]
            return [:]
        }
        diskCacheMemoryMap = dict
        return dict
    }

    private static func saveDiskCache(_ entries: [String: DiskSkillCacheEntry]) {
        diskCacheLock.lock()
        diskCacheMemoryMap = entries
        diskCacheLock.unlock()
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    /// Scan directory names of installed skills across all common skill locations
    func scanInstalledSkills() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let searchDirs = [
            home.appendingPathComponent(".gemini/config/skills"),
            home.appendingPathComponent(".gemini/antigravity/builtin/skills"),
            home.appendingPathComponent(".skills-manager/skills"),
            home.appendingPathComponent(".workbuddy/skills"),
            home.appendingPathComponent(".dsh/skills"),
            home.appendingPathComponent(".zcode/skills"),
            home.appendingPathComponent(".codex/skills")
        ]
        var result = Set<String>()
        let fm = FileManager.default
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let name = item.lastPathComponent
                    if !name.hasPrefix(".") {
                        result.insert(name)
                    }
                }
            }
        }
        return result
    }

    /// Query ZCode tool_usage / part records for Skill executions
    private func scanZCode() -> [SkillRecord] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var records: [SkillRecord] = []
        for immutable in [false, true] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            let target = immutable ? "file:\(dbPath)?immutable=1" : dbPath
            guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db = db else {
                if db != nil { sqlite3_close(db) }
                continue
            }
            sqlite3_busy_timeout(db, 3000)
            var stmt: OpaquePointer?
            let sql = "SELECT p.time_created, p.session_id, p.data FROM part p WHERE p.data LIKE '%\"tool\":\"Skill\"%'"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let ts = sqlite3_column_int64(stmt, 0)
                    let sid = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    if let textPtr = sqlite3_column_text(stmt, 2) {
                        let dataStr = String(cString: textPtr)
                        if let d = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any],
                           let state = d["state"] as? [String: Any],
                           let input = state["input"] as? [String: Any] {
                            let skill = (input["skill"] as? String) ?? (input["name"] as? String)
                            if let skill = skill?.trimmingCharacters(in: .whitespacesAndNewlines), !skill.isEmpty {
                                records.append(SkillRecord(agent: .zcode, skillName: skill, tsMs: ts, sessionId: sid))
                            }
                        }
                    }
                }
                sqlite3_finalize(stmt)
                sqlite3_close(db)
                return records
            }
            if stmt != nil { sqlite3_finalize(stmt) }
            sqlite3_close(db)
        }
        return records
    }

    /// Scan DSH compressed session logs with mtime/size persistent caching
    private func scanDsh(cache: inout [String: DiskSkillCacheEntry]) -> [SkillRecord] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions")
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        guard let workspaces = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        var records: [SkillRecord] = []
        for ws in workspaces where ws.hasDirectoryPath {
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for sDir in sessionDirs where sDir.hasDirectoryPath {
                let sid = sDir.lastPathComponent
                guard let files = try? FileManager.default.contentsOfDirectory(at: sDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for file in files where file.lastPathComponent.hasSuffix(".jsonl.zstd") {
                    let path = file.path
                    guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let mtime = attrs.contentModificationDate?.timeIntervalSince1970,
                          let size = attrs.fileSize.map(Int64.init) else { continue }

                    if let cached = cache[path], cached.mtime == mtime, cached.size == size {
                        records.append(contentsOf: cached.records)
                        continue
                    }

                    var fileRecords: [SkillRecord] = []
                    if let content = DshStatsService.decompress(file),
                       content.contains("\"skill\"") || content.contains("\"Skill\"") {
                        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                            guard (line.contains("\"skill\"") || line.contains("\"Skill\"")),
                                  line.contains("\"tool-call\""),
                                  let data = line.data(using: .utf8),
                                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            let ts = (d["time"] as? NSNumber)?.int64Value ?? 0
                            guard let payload = d["data"] as? [String: Any],
                                  let msg = payload["message"] as? [String: Any],
                                  let contentArr = msg["content"] as? [[String: Any]] else { continue }
                            for item in contentArr {
                                guard item["type"] as? String == "tool-call" else { continue }
                                let name = item["name"] as? String ?? ""
                                guard name.caseInsensitiveCompare("skill") == .orderedSame else { continue }
                                var skillName: String?
                                if let args = item["arguments"] as? [String: Any] {
                                    skillName = (args["name"] as? String) ?? (args["skill"] as? String)
                                } else if let argsStr = item["arguments"] as? String,
                                          let argsData = argsStr.data(using: .utf8),
                                          let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                                    skillName = (argsObj["name"] as? String) ?? (argsObj["skill"] as? String)
                                }
                                if let skillName = skillName?.trimmingCharacters(in: .whitespacesAndNewlines), !skillName.isEmpty {
                                    fileRecords.append(SkillRecord(agent: .dsh, skillName: skillName, tsMs: ts, sessionId: sid))
                                }
                            }
                        }
                    }

                    cache[path] = DiskSkillCacheEntry(mtime: mtime, size: size, records: fileRecords)
                    records.append(contentsOf: fileRecords)
                }
            }
        }
        return records
    }

    /// Scan WorkBuddy JSONL session logs with mtime/size persistent caching
    private func scanWorkBuddy(cache: inout [String: DiskSkillCacheEntry]) -> [SkillRecord] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects")
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }

        var records: [SkillRecord] = []
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let path = fileURL.path
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate?.timeIntervalSince1970,
                  let size = attrs.fileSize.map(Int64.init) else { continue }

            if let cached = cache[path], cached.mtime == mtime, cached.size == size {
                records.append(contentsOf: cached.records)
                continue
            }

            var fileRecords: [SkillRecord] = []
            if let content = try? String(contentsOf: fileURL, encoding: .utf8),
               content.contains("\"Skill\"") || content.contains("\"skill\"") {
                let sid = fileURL.deletingPathExtension().lastPathComponent
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard line.contains("\"function_call\""),
                          (line.contains("\"Skill\"") || line.contains("\"skill\"")),
                          let data = line.data(using: .utf8),
                          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          d["type"] as? String == "function_call" else { continue }
                    let name = d["name"] as? String ?? ""
                    guard name.caseInsensitiveCompare("skill") == .orderedSame else { continue }
                    let ts = (d["timestamp"] as? NSNumber)?.int64Value ?? 0
                    var skillName: String?
                    if let args = d["arguments"] as? [String: Any] {
                        skillName = (args["skill"] as? String) ?? (args["name"] as? String) ?? (args["command"] as? String)
                    } else if let argsStr = d["arguments"] as? String,
                              let argsData = argsStr.data(using: .utf8),
                              let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        skillName = (argsObj["skill"] as? String) ?? (argsObj["name"] as? String) ?? (argsObj["command"] as? String)
                    }
                    if let skillName = skillName?.trimmingCharacters(in: .whitespacesAndNewlines), !skillName.isEmpty {
                        fileRecords.append(SkillRecord(agent: .workbuddy, skillName: skillName, tsMs: ts, sessionId: sid))
                    }
                }
            }

            cache[path] = DiskSkillCacheEntry(mtime: mtime, size: size, records: fileRecords)
            records.append(contentsOf: fileRecords)
        }
        return records
    }

    /// Scan Antigravity transcript logs with mtime/size caching and comprehensive tool-call matching
    private func scanGemini(installed: Set<String>, cache: inout [String: DiskSkillCacheEntry]) -> [SkillRecord] {
        let brainDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain")
        guard FileManager.default.fileExists(atPath: brainDir.path) else { return [] }
        guard let convDirs = try? FileManager.default.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackIso = ISO8601DateFormatter()

        let lowerInstalled = Set(installed.map { $0.lowercased() })
        let ignoredFolders: Set<String> = ["builtin", "config", "scripts", "references", ".system", "node_modules"]

        var records: [SkillRecord] = []
        for cDir in convDirs where cDir.hasDirectoryPath {
            let transcriptURL = cDir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            let path = transcriptURL.path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let attrs = try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = attrs.contentModificationDate?.timeIntervalSince1970,
                  let size = attrs.fileSize.map(Int64.init) else { continue }

            if let cached = cache[path], cached.mtime == mtime, cached.size == size {
                records.append(contentsOf: cached.records)
                continue
            }

            var fileRecords: [SkillRecord] = []
            let sid = cDir.lastPathComponent
            if let content = try? String(contentsOf: transcriptURL, encoding: .utf8), content.contains("skills") {
                for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard line.contains("skills"),
                          let data = line.data(using: .utf8),
                          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let toolCalls = d["tool_calls"] as? [[String: Any]],
                          !toolCalls.isEmpty else { continue }

                    let dateStr = d["created_at"] as? String
                    let date = dateStr.flatMap { isoFormatter.date(from: $0) ?? fallbackIso.date(from: $0) }
                    let tsMs = Int64((date?.timeIntervalSince1970 ?? 0) * 1000)

                    for tc in toolCalls {
                        guard let args = tc["args"] as? [String: Any] else { continue }
                        var matchedInCall = Set<String>()

                        for (_, val) in args {
                            guard let strVal = val as? String, strVal.contains("skills") else { continue }
                            let parts = strVal.split(separator: "/")
                            for i in 0..<parts.count {
                                if parts[i] == "skills" && i + 1 < parts.count {
                                    var raw = String(parts[i + 1])
                                    raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\\ `;,()[]{}"))
                                    if let firstSpace = raw.firstIndex(of: " ") {
                                        raw = String(raw[..<firstSpace])
                                    }
                                    let lower = raw.lowercased()
                                    guard !lower.isEmpty && !ignoredFolders.contains(lower) else { continue }

                                    if (lowerInstalled.contains(lower) || lower.hasSuffix("-skill") || lower.hasPrefix("skill-")) && !matchedInCall.contains(lower) {
                                        matchedInCall.insert(lower)
                                        let canonical = installed.first { $0.caseInsensitiveCompare(raw) == .orderedSame } ?? raw
                                        fileRecords.append(SkillRecord(agent: .gemini, skillName: canonical, tsMs: tsMs, sessionId: sid))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            cache[path] = DiskSkillCacheEntry(mtime: mtime, size: size, records: fileRecords)
            records.append(contentsOf: fileRecords)
        }
        return records
    }

    /// Full collect across all agents and installed directories with 180s in-memory caching
    /// and persistent mtime/size disk caching
    func collectAll(force: Bool = false) -> (records: [SkillRecord], installed: Set<String>) {
        memoryLock.lock()
        if !force, let existing = cachedRecords, let installed = cachedInstalled,
           let at = lastScanAt, Date().timeIntervalSince(at) < 180 {
            memoryLock.unlock()
            return (existing, installed)
        }
        memoryLock.unlock()

        let installed = scanInstalledSkills()
        var diskCache = Self.loadDiskCache()
        let initialCount = diskCache.count

        var allRecords: [SkillRecord] = []
        allRecords.append(contentsOf: scanZCode())
        allRecords.append(contentsOf: scanDsh(cache: &diskCache))
        allRecords.append(contentsOf: scanWorkBuddy(cache: &diskCache))
        allRecords.append(contentsOf: scanGemini(installed: installed, cache: &diskCache))

        Self.saveDiskCache(diskCache)

        memoryLock.lock()
        cachedRecords = allRecords
        cachedInstalled = installed
        lastScanAt = Date()
        memoryLock.unlock()

        return (allRecords, installed)
    }
}
