import Foundation

public struct RecentTarget: Codable, Equatable, Identifiable {
    public var id: String { "\(folder)/\(note)" }
    public var folder: String
    public var note: String
    public var lastUsed: Date

    public init(folder: String, note: String, lastUsed: Date = Date()) {
        self.folder = folder
        self.note = note
        self.lastUsed = lastUsed
    }
}

@MainActor
public final class FleetingSettingsStore: ObservableObject {
    public static let shared = FleetingSettingsStore()

    private let defaults: UserDefaults
    private let pinnedKey = "CollectionBox.fleetingPinnedNotes"
    private let recentsKey = "CollectionBox.fleetingRecentTargets"
    private let lastFolderKey = "CollectionBox.fleetingLastFolder"
    private let lastNoteKey = "CollectionBox.fleetingLastNote"

    @Published public private(set) var pinnedNotes: [String] = []
    @Published public private(set) var recentTargets: [RecentTarget] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public var lastFolder: String? {
        get { defaults.string(forKey: lastFolderKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: lastFolderKey) }
            else { defaults.removeObject(forKey: lastFolderKey) }
        }
    }

    public var lastNote: String? {
        get { defaults.string(forKey: lastNoteKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: lastNoteKey) }
            else { defaults.removeObject(forKey: lastNoteKey) }
        }
    }

    public func recordTarget(folder: String, note: String) {
        lastFolder = folder
        lastNote = note

        var list = recentTargets.filter { !($0.folder == folder && $0.note == note) }
        list.insert(RecentTarget(folder: folder, note: note, lastUsed: Date()), at: 0)
        if list.count > 6 {
            list = Array(list.prefix(6))
        }
        recentTargets = list
        saveRecents()
    }

    public func removeTarget(id: String) {
        recentTargets.removeAll { $0.id == id }
        if let last = lastNote, id.hasSuffix("/\(last)") {
            lastNote = nil
            lastFolder = nil
        }
        saveRecents()
    }

    public func removeTarget(folder: String, note: String) {
        recentTargets.removeAll { $0.folder == folder && $0.note == note }
        if lastFolder == folder && lastNote == note {
            lastFolder = nil
            lastNote = nil
        }
        saveRecents()
    }

    public func clearAllTargets() {
        recentTargets.removeAll()
        lastFolder = nil
        lastNote = nil
        saveRecents()
    }

    public func pinNote(_ note: String) {
        guard !pinnedNotes.contains(note) else { return }
        pinnedNotes.append(note)
        savePinned()
    }

    public func unpinNote(_ note: String) {
        pinnedNotes.removeAll { $0 == note }
        savePinned()
    }

    private func load() {
        if let pinned = defaults.stringArray(forKey: pinnedKey) {
            self.pinnedNotes = pinned
        } else {
            self.pinnedNotes = []
        }

        if let data = defaults.data(forKey: recentsKey),
           let list = try? JSONDecoder().decode([RecentTarget].self, from: data) {
            self.recentTargets = list
        } else {
            self.recentTargets = []
        }
    }

    private func savePinned() {
        defaults.set(pinnedNotes, forKey: pinnedKey)
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentTargets) {
            defaults.set(data, forKey: recentsKey)
        }
    }
}
