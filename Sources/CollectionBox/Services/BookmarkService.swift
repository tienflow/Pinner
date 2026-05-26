import Foundation

public enum BookmarkService {
    /// Create a bookmark for the given file or folder URL.
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve a bookmark back to its URL.
    public static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            // Refresh the bookmark data (caller should persist)
            _ = try? makeBookmark(for: url)
        }
        return url
    }

    /// Resolve bookmark and run a closure with access to the resource.
    public static func withResolvedBookmark<T>(_ data: Data, perform: (URL) throws -> T) rethrows -> T? {
        guard let url = try? resolveBookmark(data) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? perform(url)
    }

    /// Check if a bookmark is still valid and return current filename if available.
    public static func verifyBookmark(_ data: Data) -> (valid: Bool, currentName: String?) {
        guard let url = try? resolveBookmark(data) else { return (false, nil) }
        if FileManager.default.fileExists(atPath: url.path) {
            return (true, url.lastPathComponent)
        }
        return (false, nil)
    }

    /// Try to re-create a bookmark from the resolved URL (if file still exists).
    public static func refreshBookmark(_ data: Data) -> (newData: Data?, currentName: String?) {
        guard let url = try? resolveBookmark(data),
              FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        let newData = try? makeBookmark(for: url)
        return (newData, url.lastPathComponent)
    }
}
