import Foundation

public struct CollectionTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var entries: [BookmarkEntry]

    public init(id: UUID, name: String, entries: [BookmarkEntry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

public struct BookmarkEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmarkData: Data
    public var dateAdded: Date
    public var lastOpened: Date?
    public var isPinned: Bool
    /// True when the bookmark could not be resolved during the last refresh
    /// (file moved/deleted, volume unmounted). The entry is kept and shown as
    /// "未找到" instead of being silently removed.
    public var isMissing: Bool

    public init(id: UUID, displayName: String, bookmarkData: Data, dateAdded: Date = Date(), lastOpened: Date? = nil, isPinned: Bool = false, isMissing: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.dateAdded = dateAdded
        self.lastOpened = lastOpened
        self.isPinned = isPinned
        self.isMissing = isMissing
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, bookmarkData, dateAdded, lastOpened, isPinned, isMissing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        bookmarkData = try c.decode(Data.self, forKey: .bookmarkData)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isMissing = try c.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
    }
}

/// Persisted panel geometry. The panel is anchored to the mouse / menu bar on
/// expand, so only its size is remembered between sessions.
public struct WindowState: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public static let defaultState = WindowState(width: 320, height: 480)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
