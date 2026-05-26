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

    public init(id: UUID, displayName: String, bookmarkData: Data) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

/// Persisted window geometry and expand/collapse state.
public struct WindowState: Codable, Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double
    public var isExpanded: Bool

    public init(originX: Double, originY: Double, width: Double, height: Double, isExpanded: Bool) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.isExpanded = isExpanded
    }
}
