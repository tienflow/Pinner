import Foundation
import AppKit

/// A specialized `NSURL` subclass for files dragged out of the temporary shelf.
///
/// Because it is a true `NSURL`, macOS AppKit and Finder automatically generate
/// full native pasteboard types (including `NSFilenamesPboardType` and CorePasteboard flavors),
/// ensuring that target applications (Finder, Desktop, Terminal, WeChat, etc.) can 100% reliably
/// receive and write the file.
///
/// When the external target finishes accepting the drop and invokes `loadData`,
/// this class schedules `onConsumed` to safely remove the entry from the shelf,
/// and optionally move the original file to the Trash to achieve a complete physical cut/move effect.
public final class ShelfFileNSURL: NSURL, @unchecked Sendable {
    public let entryIDs: [UUID]
    public let sourceURL: URL
    public let onConsumed: @Sendable ([UUID], URL) -> Void

    private let lock = NSLock()
    private var hasTriggered = false

    public init(fileURL: URL, entryIDs: [UUID], onConsumed: @escaping @Sendable ([UUID], URL) -> Void) {
        self.sourceURL = fileURL
        self.entryIDs = entryIDs
        self.onConsumed = onConsumed
        super.init(fileURLWithPath: fileURL.path)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) has not been implemented")
    }

    public override func loadData(
        withTypeIdentifier typeIdentifier: String,
        forItemProviderCompletionHandler completionHandler: @escaping (Data?, Error?) -> Void
    ) -> Progress? {
        let progress = super.loadData(withTypeIdentifier: typeIdentifier, forItemProviderCompletionHandler: completionHandler)

        lock.lock()
        let shouldTrigger = !hasTriggered
        if shouldTrigger {
            hasTriggered = true
        }
        lock.unlock()

        if shouldTrigger {
            // Small delay (0.5s) to guarantee the recipient application has finished copying the file
            // from the source path before Pinner post-processes it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.onConsumed(self.entryIDs, self.sourceURL)
            }
        }

        return progress
    }
}
