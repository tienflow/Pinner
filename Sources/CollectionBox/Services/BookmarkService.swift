import Foundation

public enum BookmarkService {
    /// Check if a file URL is in the Trash.
    static func isTrashed(_ url: URL) -> Bool {
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        let trashPath = trash?.path ?? ""
        return !trashPath.isEmpty && url.path.hasPrefix(trashPath)
    }

    /// Check if a file exists and is not in the Trash.
    static func isFileValid(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && !isTrashed(url)
    }

    /// Create a bookmark for the given file or folder URL.
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve a bookmark back to its URL. Stale bookmarks are left to
    /// `refreshBookmark`, which persists regenerated data.
    public static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Resolve a bookmark to a URL without validating existence.
    public static func resolveURL(_ data: Data) -> URL? {
        try? resolveBookmark(data)
    }

    /// Standardized filesystem path for a bookmark, used for de-duplication.
    public static func resolvedPath(_ data: Data) -> String? {
        guard let url = try? resolveBookmark(data) else { return nil }
        return url.standardizedFileURL.path
    }

    /// Resolve bookmark and run a closure with access to the resource.
    public static func withResolvedBookmark<T>(_ data: Data, perform: (URL) throws -> T) rethrows -> T? {
        guard let url = try? resolveBookmark(data), isFileValid(url) else { return nil }
        return try? perform(url)
    }

    /// Check if a bookmark is still valid and return current filename if available.
    public static func verifyBookmark(_ data: Data) -> (valid: Bool, currentName: String?) {
        guard let url = try? resolveBookmark(data) else { return (false, nil) }
        if isFileValid(url) {
            return (true, url.lastPathComponent)
        }
        return (false, nil)
    }

    /// Try to re-create a bookmark from the resolved URL (if file still exists).
    /// Callers are responsible for persisting `newData`.
    public static func refreshBookmark(_ data: Data) -> (newData: Data?, currentName: String?) {
        guard let url = try? resolveBookmark(data),
              isFileValid(url) else { return (nil, nil) }
        let newData = try? makeBookmark(for: url)
        return (newData, url.lastPathComponent)
    }
}
