import Foundation
import AppKit
import Combine

/// One user-defined rename: records reported as `raw` are displayed as
/// `canonical` everywhere in the dashboard. Both sides are matched
/// case-insensitively; `canonical` keeps the casing the user typed.
public struct ModelAlias: Codable, Identifiable, Sendable, Equatable {
    public var id: String { raw.lowercased() }
    public let raw: String
    public let canonical: String

    public init(raw: String, canonical: String) {
        self.raw = raw
        self.canonical = canonical
    }
}

/// The on-disk shape. Versioned so a future format change can migrate rather
/// than silently discard a hand-edited file.
struct ModelAliasFile: Codable, Sendable {
    var version: Int
    var aliases: [ModelAlias]
}

/// An immutable snapshot of the resolution rules. `buildSnapshot` runs in a
/// detached task, so it must receive plain values rather than the observable
/// service.
public struct ModelAliasTable: Sendable {
    /// lowercased raw -> canonical, last write wins.
    public let index: [String: String]
    /// Built-in suffix list in effect, kept alongside the index so a table
    /// built by an older caller still strips what it was built with.
    public let suffixes: [String]

    public init(index: [String: String] = [:], suffixes: [String] = ModelAliasService.builtinSuffixes) {
        self.index = index
        self.suffixes = suffixes
    }

    /// Strips the longest matching suffix, never down to an empty string: a
    /// model literally named `-n` stays as it is.
    func stripBuiltinSuffix(from raw: String) -> String {
        let lower = raw.lowercased()
        for suffix in suffixes.sorted(by: { $0.count > $1.count }) {
            guard lower.hasSuffix(suffix) else { continue }
            let base = String(raw.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return raw
    }

    /// The name to display for `raw`, or `nil` when the agent reported no
    /// model (the caller keeps its per-agent "unknown" bucket).
    public func canonicalName(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        // 1. Exact user alias, including identity mappings that opt out of
        //    the built-in rules.
        if let hit = index[raw.lowercased()] { return hit }

        // 2. Built-in suffix stripping, then re-check aliases so a user can
        //    still name the merged result.
        let stripped = stripBuiltinSuffix(from: raw)
        if stripped != raw, let hit = index[stripped.lowercased()] { return hit }

        return stripped
    }
}

/// Resolves the model name an agent reported into the name the dashboard
/// shows. Two layers, in priority order:
///
/// 1. **User aliases** — an exact (case-insensitive) match on the raw name
///    wins outright, including a mapping whose canonical equals its raw. That
///    last case is how a user opts out of the built-in rules for one model.
/// 2. **Built-in suffixes** — a small, explicit blacklist of routing suffixes
///    upstream tools append when they re-route a model. A wildcard regex is
///    deliberately not used: suffixes like `-lite`, `-high` or `-medium` are
///    real capability/tier markers, and folding them would merge genuinely
///    different things and quietly corrupt the totals.
///
/// The table is user-editable and stored as JSON so it can be inspected,
/// diffed and hand-edited. A malformed file never breaks the dashboard: it
/// falls back to an empty table and surfaces `loadFailed` so the UI can warn.
public final class ModelAliasService: ObservableObject {
    public static let shared = ModelAliasService()

    /// Routing-only suffixes stripped by default. Keep this list explicit and
    /// minimal — every entry silently merges two differently-named records.
    public static let builtinSuffixes: [String] = ["-n", "-tiered"]

    /// File format version written by this build.
    static let currentVersion = 1

    @Published public private(set) var aliases: [ModelAlias] = []
    @Published public private(set) var loadFailed = false

    private let fileURL: URL
    /// lowercased raw -> canonical, rebuilt on every mutation.
    private var index: [String: String] = [:]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pinner/model-aliases.json")
    }

    /// A value snapshot for off-main consumers.
    public var table: ModelAliasTable {
        ModelAliasTable(index: index, suffixes: Self.builtinSuffixes)
    }

    // MARK: - Resolution

    /// The name to display for `raw`, or `nil` when the agent reported no
    /// model (the caller keeps its per-agent "unknown" bucket).
    public func canonicalName(for raw: String?) -> String? {
        table.canonicalName(for: raw)
    }

    /// Drops a trailing built-in suffix, but never to an empty string.
    static func stripBuiltinSuffix(from raw: String) -> String {
        ModelAliasTable().stripBuiltinSuffix(from: raw)
    }

    // MARK: - Mutation

    /// Adds or replaces the alias for `raw`. Returns false when the input is
    /// unusable (blank either side).
    @discardableResult
    public func upsert(raw: String, canonical: String) -> Bool {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !c.isEmpty else { return false }
        let entry = ModelAlias(raw: r, canonical: c)
        var next = aliases.filter { $0.raw.lowercased() != r.lowercased() }
        next.append(entry)
        // Sort so the settings list and the file stay in a stable order that
        // diffs cleanly when hand-edited.
        aliases = next.sorted { $0.raw.lowercased() < $1.raw.lowercased() }
        persist()
        return true
    }

    public func remove(_ alias: ModelAlias) {
        aliases.removeAll { $0.raw.lowercased() == alias.raw.lowercased() }
        persist()
    }

    /// Clears the user layer only. Built-in suffixes always apply.
    public func removeAll() {
        guard !aliases.isEmpty else { return }
        aliases = []
        persist()
    }

    /// Distinct raw names that fold into `canonical`, given everything the
    /// dashboard currently sees. Drives the "已合并 N 个原始 ID" affordance so
    /// a merge is never invisible.
    public func mergedSources(for canonical: String, observed rawNames: [String]) -> [String] {
        let target = canonical.lowercased()
        var seen = Set<String>()
        for raw in rawNames where canonicalName(for: raw)?.lowercased() == target {
            seen.insert(raw)
        }
        return seen.sorted()
    }

    // MARK: - Persistence

    private func load() {
        loadFailed = false
        guard let data = try? Data(contentsOf: fileURL) else {
            aliases = []
            rebuildIndex()
            return
        }
        do {
            let decoded = try JSONDecoder().decode(ModelAliasFile.self, from: data)
            aliases = decoded.aliases
            loadFailed = false
        } catch {
            // Never let a hand-edit break the dashboard: drop to an empty
            // table and let the settings UI warn about the bad file.
            aliases = []
            loadFailed = true
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        var map: [String: String] = [:]
        for a in aliases { map[a.raw.lowercased()] = a.canonical }
        index = map
    }

    private func persist() {
        rebuildIndex()
        let payload = ModelAliasFile(version: Self.currentVersion, aliases: aliases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Reveals the file in Finder, creating it first if it does not exist yet
    /// so the user always lands on something editable.
    public func revealInFinder() {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) { persist() }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
