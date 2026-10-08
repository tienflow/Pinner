import Foundation

/// Shared JSONL reading for the session-log scanners.
///
/// The stats side (`WorkBuddyStatsService`) and the skill side
/// (`SkillStatsService`) both walk the same `~/.workbuddy/projects` tree and the
/// same `.zstd` session payloads, but they used different strategies:
///
/// - stats: `Data(contentsOf:options:.mappedIfSafe)` + byte-level tag search
/// - skills: `String(contentsOf:encoding:.utf8)` + whole-string `contains`
///
/// The second form decodes the entire file into a Swift String and then scans
/// it three times (`contains`, `contains`, `split`), so a Dashboard refresh paid
/// for two full reads of ~270 MB plus DSH decompressing every archive twice.
/// Both sides now go through this helper: one mmap, one line split, and callers
/// filter with a cheap byte-level tag test before paying for JSON parsing.
enum JSONLReader {
    /// Iterates the lines of a JSONL file without materializing a Swift String
    /// for the whole file. The closure receives a `Data.SubSequence` that points
    /// into the mapped pages, so it is valid only for the duration of the call.
    ///
    /// `requiredTags` short-circuits: a line that contains none of the tags can
    /// be skipped without any JSON parsing. Pass an empty array to parse every
    /// line.
    static func forEachLine(
        of url: URL,
        requiredTags: [Data],
        _ body: (Data.SubSequence) -> Void
    ) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return }
        let newline = Data([0x0A])
        for line in data.split(separator: newline) {
            if !requiredTags.isEmpty {
                let matches = requiredTags.contains { line.firstRange(of: $0) != nil }
                if !matches { continue }
            }
            body(line)
        }
    }
}
