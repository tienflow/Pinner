import Foundation

public enum BookmarkService {
    /// Create a security-scoped bookmark for the given file or folder URL.
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark back to its URL.
    public static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            let fresh = try makeBookmark(for: url)
            _ = fresh
        }
        return url
    }

    /// Resolve bookmark and run a closure with access to the resource.
    /// Automatically starts/stops security-scoped access.
    public static func withResolvedBookmark<T>(_ data: Data, perform: (URL) throws -> T) rethrows -> T? {
        guard let url = try? resolveBookmark(data) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        return try? perform(url)
    }
}
