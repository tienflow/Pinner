import Foundation

public enum BookmarkService {
    /// Create a bookmark for the given file or folder URL.
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a bookmark back to its URL.
    public static func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
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
    public static func withResolvedBookmark<T>(_ data: Data, perform: (URL) throws -> T) rethrows -> T? {
        guard let url = try? resolveBookmark(data) else {
            print("[BookmarkService] Failed to resolve bookmark")
            return nil
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        print("[BookmarkService] Resolved URL: \(url.path), exists: \(exists)")

        guard exists else { return nil }
        return try perform(url)
    }

}
