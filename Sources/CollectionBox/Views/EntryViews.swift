import SwiftUI
import AppKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Entry presentation shared by the list and grid layouts, plus the icon/thumbnail
// pipeline. Split out of RootView.swift so the panel’s state machine stays readable.

// MARK: - Entry Row (List)

struct EntryRow: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false
    /// Optional source-tab label shown in cross-tab views (recents).
    var sourceLabel: String? = nil
    var onReorderDrop: ([NSItemProvider]) -> Bool = { _ in false }
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            FileIconView(entry: entry, prefersThumbnail: false).frame(width: 20, height: 20).opacity(entry.isMissing ? 0.4 : 1)
            Text(entry.displayName).font(.system(size: Design.body)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
            if entry.isMissing {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: Design.micro)).foregroundStyle(.orange)
            }
            if let sourceLabel {
                Text(sourceLabel).font(.system(size: Design.micro)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
        }.padding(.vertical, 3).padding(.horizontal, 6)
        .background(isFlashing ? Color.accentColor.opacity(Design.flashAlpha)
            : isSelected ? Color.accentColor.opacity(Design.selectedAlpha)
            : isHovered ? Color.secondary.opacity(Design.hoverAlpha) : Color.clear)
        .overlay(alignment: .top) {
            // Always present, toggled by opacity: adding/removing the branch
            // mid-drag invalidates the active drag session on macOS.
            Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: Design.radiusS)
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Design.radiusS))
        .onDrop(of: [.pinnerEntry, .plainText], isTargeted: $isDropTargeted) { onReorderDrop($0) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
    }
}

// MARK: - Grid Item

struct GridEntryItem: View {
    let entry: BookmarkEntry
    var isSelected = false
    var isFlashing = false
    var onReorderDrop: ([NSItemProvider]) -> Bool = { _ in false }
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 4) {
            FileIconView(entry: entry).frame(width: 48, height: 48).frame(width: 56, height: 56)
                .background(Color.secondary.opacity(Design.wellAlpha)).cornerRadius(Design.radiusM)
                .overlay(alignment: .topTrailing) {
                    if entry.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                            .offset(x: 3, y: -3)
                    }
                }
            Text(entry.displayName).font(.system(size: Design.ui)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(entry.isMissing ? .secondary : .primary)
                .frame(width: 76, height: 14, alignment: .top)
        }
        .frame(width: 80, height: 86)
        .background(RoundedRectangle(cornerRadius: Design.radiusM).fill(isFlashing ? Color.accentColor.opacity(Design.flashAlpha)
            : isSelected ? Color.accentColor.opacity(Design.selectedAlpha)
            : isHovered ? Color.secondary.opacity(Design.hoverAlpha) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Design.radiusM)
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
        .overlay(alignment: .top) {
            // Always present, toggled by opacity: adding/removing the branch
            // mid-drag invalidates the active drag session on macOS.
            Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .onDrop(of: [.pinnerEntry, .plainText], isTargeted: $isDropTargeted) { onReorderDrop($0) }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isMissing ? "\(entry.displayName)，未找到" : entry.displayName)
    }
}

// MARK: - File Icon

struct FileIconView: View {
    let entry: BookmarkEntry
    var prefersThumbnail = true
    var body: some View { FileIconWrap(entry: entry, prefersThumbnail: prefersThumbnail) }
}

#if canImport(AppKit)
struct FileIconWrap: NSViewRepresentable {
    let entry: BookmarkEntry
    /// Grid cells show a content preview; list rows keep the plain file icon.
    var prefersThumbnail = true
    static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private static let thumbnailableExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "pdf"]
    /// Bookmark resolution touches the filesystem (milliseconds each), so
    /// results are cached per entry and invalidated when the bookmark data
    /// changes. Main-thread only, like every caller below.
    private static var resolvedPathCache: [UUID: (bookmark: Data, path: String?)] = [:]
    /// Paths with a thumbnail request already in flight. Without this, every
    /// re-render of a visible cell would queue another generation request.
    nonisolated(unsafe) private static var pendingThumbnails: Set<String> = []
    /// Negative cache for files whose thumbnail generation failed, avoiding infinite retry loops.
    nonisolated(unsafe) private static var failedThumbnails: Set<String> = []
    private static let pendingLock = NSLock()

    // Icons and thumbnails share NSCache but must never share a key: the icon
    // is written first, so a thumbnail lookup on the same key would hit it.
    private static func iconKey(_ path: String) -> NSString { ("icon:" + path) as NSString }
    private static func thumbnailKey(_ path: String) -> NSString { ("thumb:" + path) as NSString }

    static func cachedResolvedPath(for entry: BookmarkEntry) -> String? {
        if let hit = resolvedPathCache[entry.id], hit.bookmark == entry.bookmarkData { return hit.path }
        let path = BookmarkService.resolvedPath(entry.bookmarkData)
        resolvedPathCache[entry.id] = (entry.bookmarkData, path)
        return path
    }

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView(); v.imageScaling = .scaleProportionallyUpOrDown
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        if prefersThumbnail, let path = Self.cachedResolvedPath(for: entry),
           let cached = Self.iconCache.object(forKey: Self.thumbnailKey(path)) {
            v.image = cached
            return v
        }
        v.image = Self.baseIcon(for: entry)
        if prefersThumbnail {
            Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
                if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
            }
        }
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        v.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        if prefersThumbnail, let path = Self.cachedResolvedPath(for: entry),
           let cached = Self.iconCache.object(forKey: Self.thumbnailKey(path)) {
            v.image = cached
            return
        }
        v.image = Self.baseIcon(for: entry)
        guard prefersThumbnail else { return }
        Self.loadThumbnailIfAvailable(for: entry) { thumbnail in
            if v.identifier?.rawValue == entry.id.uuidString { v.image = thumbnail }
        }
    }

    static func baseIcon(for entry: BookmarkEntry) -> NSImage {
        let path = cachedResolvedPath(for: entry)
        let ext = path.map { ($0 as NSString).pathExtension } ?? (entry.displayName as NSString).pathExtension
        let fallback = ext.isEmpty
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .item)
        guard let path = path else { return fallback }
        let key = iconKey(path)
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Decodes an image/PDF/media/document thumbnail via system QLThumbnailGenerator
    /// off the main thread with fallback, and caches it under its own key.
    static func loadThumbnailIfAvailable(for entry: BookmarkEntry, completion: @escaping (NSImage) -> Void) {
        guard let path = cachedResolvedPath(for: entry) else { return }
        let pathExt = (path as NSString).pathExtension.lowercased()
        let nameExt = (entry.displayName as NSString).pathExtension.lowercased()
        let ext = !pathExt.isEmpty ? pathExt : nameExt
        guard thumbnailableExtensions.contains(ext) else { return }
        let cachedKey = thumbnailKey(path)
        if let cached = iconCache.object(forKey: cachedKey) {
            completion(cached)
            return
        }

        pendingLock.lock()
        guard !failedThumbnails.contains(path) else { pendingLock.unlock(); return }
        guard !pendingThumbnails.contains(path) else { pendingLock.unlock(); return }
        pendingThumbnails.insert(path)
        pendingLock.unlock()

        let url = URL(fileURLWithPath: path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 128, height: 128),
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            if let rep = rep {
                Self.publishThumbnail(rep.nsImage, for: path, key: cachedKey, completion: completion)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let thumb = Self.thumbnail(at: path, ext: ext, maxPixel: 256) else {
                    Self.markThumbnailFailed(path)
                    return
                }
                Self.publishThumbnail(thumb, for: path, key: cachedKey, completion: completion)
            }
        }
    }

    private static func clearPendingThumbnail(_ path: String) {
        pendingLock.lock()
        pendingThumbnails.remove(path)
        pendingLock.unlock()
    }

    private static func markThumbnailFailed(_ path: String) {
        pendingLock.lock()
        pendingThumbnails.remove(path)
        failedThumbnails.insert(path)
        pendingLock.unlock()
    }

    private static func publishThumbnail(_ image: NSImage, for path: String, key: NSString,
                                         completion: @escaping (NSImage) -> Void) {
        clearPendingThumbnail(path)
        iconCache.setObject(image, forKey: key)
        DispatchQueue.main.async { completion(image) }
    }

    static func thumbnail(at path: String, ext: String, maxPixel: Int) -> NSImage? {
        if ext == "pdf" {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
                  let page = doc.page(at: 0) else { return nil }
            let thumb = page.thumbnail(of: CGSize(width: maxPixel, height: maxPixel), for: .mediaBox)
            return thumb
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
#else
struct FileIconWrap: View { let entry: BookmarkEntry; var body: some View { Image(systemName: "doc").font(.system(size: 24)) } }
#endif
