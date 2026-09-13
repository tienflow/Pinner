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

    struct Record {
        let tsMs: Int64
        let tokens: Int
        let freshInput: Int
        let cached: Int
        let output: Int
        let sessionId: String
        let model: String?
        let title: String?
    }

    func collectRecords(sinceMs: Int64) -> [Record] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        let minDate = Date(timeIntervalSince1970: TimeInterval(sinceMs) / 1000)

        var records: [Record] = []
        guard let workspaceDirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

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
                    at: sessionDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }

                for file in files where file.lastPathComponent.hasSuffix(".jsonl.zstd") {
                    guard let content = Self.decompress(file) else { continue }
                    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                        guard line.contains("\"usage\""),
                              let data = line.data(using: .utf8),
                              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              d["type"] as? String == "assistant/message",
                              let payload = d["data"] as? [String: Any],
                              let usage = payload["usage"] as? [String: Any] else { continue }

                        guard let timeNumber = d["time"] as? NSNumber else { continue }
                        let tsMs = timeNumber.int64Value
                        if tsMs < sinceMs { continue }

                        var model: String?
                        if let message = payload["message"] as? [String: Any],
                           let source = message["source"] as? [String: Any],
                           let m = source["model"] as? String, !m.isEmpty {
                            model = m
                        }

                        records.append(Record(
                            tsMs: tsMs,
                            tokens: (usage["totalTokens"] as? NSNumber)?.intValue ?? 0,
                            freshInput: (usage["inputTokens"] as? NSNumber)?.intValue ?? 0,
                            cached: (usage["cacheReadTokens"] as? NSNumber)?.intValue ?? 0,
                            output: (usage["outputTokens"] as? NSNumber)?.intValue ?? 0,
                            sessionId: sessionId,
                            model: model,
                            title: projectTitle
                        ))
                    }
                }
            }
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
