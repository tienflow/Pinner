import Foundation

// zstd FFI — linked from Homebrew (see Package.swift linkerSettings).
@_silgen_name("ZSTD_getFrameContentSize")
private func zstd_getFrameContentSize(_ src: UnsafeRawPointer, _ srcSize: Int) -> UInt64
@_silgen_name("ZSTD_decompress")
private func zstd_decompress(_ dst: UnsafeMutableRawPointer, _ dstCap: Int, _ src: UnsafeRawPointer, _ srcSize: Int) -> Int
@_silgen_name("ZSTD_isError")
private func zstd_isError(_ code: Int) -> UInt
@_silgen_name("ZSTD_getErrorName")
private func zstd_getErrorName(_ code: Int) -> UnsafePointer<CChar>

/// Token usage of the DeepSeek Harness (DSH), scanned from
/// `~/.dsh/sessions/<workspace>/<session>/session*.jsonl.zstd`.
///
/// Each `assistant/message` event carries `data.usage =
/// {inputTokens, outputTokens, totalTokens, cacheReadTokens}` where
/// total = input + cache + output (input excludes cached reads). The
/// per-event stream chunks duplicate the final usage — only the top-level
/// `data.usage` is taken. The model name rides on
/// `data.message.source.model`.
final class DshStatsService {
    private let sessionsDir: URL

    init() {
        sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions")
    }

    private struct Record: Codable, Sendable {
        let tsMs: Int64
        let tokens: Int
        let freshInput: Int
        let cached: Int
        let output: Int
        let sessionId: String
        let model: String?
        let title: String?
        let durationMs: Int?

        var asPublic: PublicRecord {
            PublicRecord(tsMs: tsMs, tokens: tokens, freshInput: freshInput, cached: cached,
                         output: output, sessionId: sessionId, model: model, title: title,
                         durationMs: durationMs)
        }
    }

    private struct DiskFileCacheEntry: Codable, Sendable {
        let mtime: TimeInterval
        let size: Int64
        let records: [Record]
    }

    // A full scan decompresses every session file; cache the newest scan
    // briefly so dashboard reloads share it (same pattern as WorkBuddy).
    private struct ScanCache {
        let sinceMs: Int64
        let records: [Record]
        let at: Date
    }

    private static let cacheLock = NSLock()
    private static var scanCache: ScanCache?
    private static var persistentCache: [String: DiskFileCacheEntry]?

    private static let cacheFileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let dir = base.appendingPathComponent("com.tienyeung.Pinner")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("dsh_scan_cache.json")
        try? FileManager.default.removeItem(at: legacy)
        return dir.appendingPathComponent("dsh_scan_cache_v2.json")
    }()

    private static func getDiskCache() -> [String: DiskFileCacheEntry] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = persistentCache { return existing }
        let loaded = loadDiskCache()
        persistentCache = loaded
        return loaded
    }

    private static func loadDiskCache() -> [String: DiskFileCacheEntry] {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let dict = try? JSONDecoder().decode([String: DiskFileCacheEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func updateDiskCache(_ newEntries: [String: DiskFileCacheEntry]) {
        guard !newEntries.isEmpty else { return }
        cacheLock.lock()
        var current = persistentCache ?? loadDiskCache()
        for (k, v) in newEntries {
            current[k] = v
        }
        persistentCache = current
        cacheLock.unlock()
        if let data = try? JSONEncoder().encode(current) {
            try? data.write(to: cacheFileURL, options: .atomic)
        }
    }

    struct PublicRecord {
        let tsMs: Int64
        let tokens: Int
        let freshInput: Int
        let cached: Int
        let output: Int
        let sessionId: String
        let model: String?
        let title: String?
        let durationMs: Int?
    }

    func collectRecords(sinceMs: Int64) -> [PublicRecord] {
        Self.cacheLock.lock()
        let cached = Self.scanCache
        Self.cacheLock.unlock()
        if let cached = cached, cached.sinceMs <= sinceMs,
           Date().timeIntervalSince(cached.at) < 120 {
            return cached.records.filter { $0.tsMs >= sinceMs }.map(\.asPublic)
        }
        let records = scan(sinceMs: sinceMs)
        Self.cacheLock.lock()
        Self.scanCache = ScanCache(sinceMs: sinceMs, records: records, at: Date())
        Self.cacheLock.unlock()
        return records.map(\.asPublic)
    }

    private func scan(sinceMs: Int64) -> [Record] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        let minDate = Date(timeIntervalSince1970: TimeInterval(sinceMs) / 1000)

        var records: [Record] = []
        guard let workspaceDirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        let diskCache = Self.getDiskCache()
        var newEntries: [String: DiskFileCacheEntry] = [:]

        for workspace in workspaceDirs where workspace.hasDirectoryPath {
            let projectTitle = decodeWorkspaceName(workspace.lastPathComponent)
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }

            for sessionDir in sessionDirs where sessionDir.hasDirectoryPath {
                if let values = try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mdate = values.contentModificationDate, mdate < minDate {
                    continue
                }
                let sessionId = sessionDir.lastPathComponent
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }

                for file in files where file.lastPathComponent.hasSuffix(".jsonl.zstd") {
                    let filePath = file.path
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let fileSize = Int64(values?.fileSize ?? 0)

                    if let entry = diskCache[filePath], entry.mtime == mtime && entry.size == fileSize {
                        records.append(contentsOf: entry.records.filter { $0.tsMs >= sinceMs })
                        continue
                    }

                    guard let content = Self.decompress(file) else { continue }
                    var fileRecords: [Record] = []
                    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                        guard line.contains("\"usage\""),
                              let data = line.data(using: .utf8),
                              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              d["type"] as? String == "assistant/message",
                              let payload = d["data"] as? [String: Any],
                              let usage = payload["usage"] as? [String: Any] else { continue }

                        guard let timeNumber = d["time"] as? NSNumber else { continue }
                        let tsMs = timeNumber.int64Value

                        var model: String?
                        if let message = payload["message"] as? [String: Any],
                           let source = message["source"] as? [String: Any],
                           let m = source["model"] as? String, !m.isEmpty {
                            model = m
                        }

                        var durationMs: Int? = nil
                        if let stream = payload["stream"] as? [[String: Any]],
                           let firstTime = stream.first?["time"] as? NSNumber {
                            let diff = tsMs - firstTime.int64Value
                            if diff >= 100 { durationMs = Int(diff) }
                        }

                        fileRecords.append(Record(
                            tsMs: tsMs,
                            tokens: (usage["totalTokens"] as? NSNumber)?.intValue ?? 0,
                            freshInput: (usage["inputTokens"] as? NSNumber)?.intValue ?? 0,
                            cached: (usage["cacheReadTokens"] as? NSNumber)?.intValue ?? 0,
                            output: (usage["outputTokens"] as? NSNumber)?.intValue ?? 0,
                            sessionId: sessionId,
                            model: model,
                            title: projectTitle,
                            durationMs: durationMs
                        ))
                    }

                    newEntries[filePath] = DiskFileCacheEntry(mtime: mtime, size: fileSize, records: fileRecords)
                    records.append(contentsOf: fileRecords.filter { $0.tsMs >= sinceMs })
                }
            }
        }

        if !newEntries.isEmpty {
            Self.updateDiskCache(newEntries)
        }
        return records
    }

    /// "--Users-apple-Documents-My_Code-Dev--" → "/Users/apple/Documents/My_Code/Dev"
    private func decodeWorkspaceName(_ name: String) -> String? {
        var s = name
        if s.hasPrefix("--") { s.removeFirst(2) }
        if s.hasSuffix("--") { s.removeLast(2) }
        guard !s.isEmpty else { return nil }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }

    /// Decompress a .zstd file via libzstd. Single-frame assumption with a
    /// doubling fallback when the frame content size is unknown.
    static func decompress(_ url: URL) -> String? {
        guard let compressed = try? Data(contentsOf: url), !compressed.isEmpty else { return nil }
        var capacity: Int
        let declared = compressed.withUnsafeBytes { ptr -> UInt64 in
            guard let base = ptr.baseAddress else { return 0 }
            return zstd_getFrameContentSize(base.assumingMemoryBound(to: UInt8.self), ptr.count)
        }
        if declared > 0, declared < UInt64(Int.max) {
            capacity = Int(declared)
        } else {
            capacity = max(compressed.count * 4, 1 << 16)
        }

        for _ in 0..<6 {
            var dst = Data(count: capacity)
            let result = dst.withUnsafeMutableBytes { dstPtr -> Int in
                compressed.withUnsafeBytes { srcPtr -> Int in
                    zstd_decompress(dstPtr.baseAddress!, dstPtr.count,
                                    srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), srcPtr.count)
                }
            }
            if result >= 0, zstd_isError(result) == 0 {
                dst.removeSubrange(result...)
                return String(data: dst, encoding: .utf8)
            }
            capacity *= 4
        }
        return nil
    }
}
