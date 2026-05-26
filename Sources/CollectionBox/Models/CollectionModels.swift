import Foundation

struct CollectionTab: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var entries: [BookmarkEntry]
}

struct BookmarkEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
}

/// Persisted window geometry and expand/collapse state.
struct WindowState: Codable, Equatable {
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    var isExpanded: Bool
}
