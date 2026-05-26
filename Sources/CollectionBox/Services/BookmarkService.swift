import Foundation

enum BookmarkService {
    /// Create a security-scoped bookmark for the given file or folder URL.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a security-scoped bookmark back to its URL.
    /// Throws if the bookmark data is invalid or cannot be resolved.
    static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            // Re-create the bookmark to refresh it
            let fresh = try makeBookmark(for: url)
            _ = fresh // In production, persist this back
        }
        return url
    }
}
