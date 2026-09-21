import Foundation
import UniformTypeIdentifiers

/// An `NSItemProviderWriting` wrapper for files dragged out of the temporary shelf.
///
/// When the recipient application finishes accepting the drop and reads the file URL data,
/// this provider automatically triggers the `onConsumed` callback with the associated
/// entry IDs so they are immediately removed from the temporary shelf ("auto-remove / 拖出即焚").
public final class ShelfURLItem: NSObject, @unchecked Sendable, NSItemProviderWriting {
    public let url: URL
    public let entryIDs: [UUID]
    public let onConsumed: @Sendable ([UUID]) -> Void

    private let lock = NSLock()
    private var hasTriggered = false

    public init(url: URL, entryIDs: [UUID], onConsumed: @escaping @Sendable ([UUID]) -> Void) {
        self.url = url
        self.entryIDs = entryIDs
        self.onConsumed = onConsumed
        super.init()
    }

    public static var writableTypeIdentifiersForItemProvider: [String] {
        return ["public.file-url", "public.url"]
    }

    public func loadData(
        withTypeIdentifier typeIdentifier: String,
        forItemProviderCompletionHandler completionHandler: @escaping (Data?, Error?) -> Void
    ) -> Progress? {
        let progress = (url as NSURL).loadData(withTypeIdentifier: typeIdentifier) { data, error in
            completionHandler(data, error)
        }

        lock.lock()
        let shouldTrigger = !hasTriggered
        if shouldTrigger {
            hasTriggered = true
        }
        lock.unlock()

        if shouldTrigger {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onConsumed(self.entryIDs)
            }
        }

        return progress
    }
}
