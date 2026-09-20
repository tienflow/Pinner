import SwiftUI
import AppKit

/// Multi-line text input that grows with its content (single-line for short
/// text, up to `maxHeight`). Enter submits (via `onSubmit`); Shift+Enter
/// inserts a newline. Includes a placeholder drawn when empty.
struct AutoGrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String = ""
    var minHeight: CGFloat = 30
    var maxHeight: CGFloat = 100
    var autoFocus: Bool = false
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Do NOT use NSTextView.scrollableTextView(): it returns a plain
        // NSTextView, not our PlaceholderTextView subclass, and `as!` would
        // trap at runtime. Build the scroll view and its document view by hand.
        let scrollView = NSScrollView()
        let textView = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: Design.body)
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 30)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = context.environment.isEnabled
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        // The rounded chrome is drawn by SwiftUI (background/overlay), so the
        // scroll view itself stays borderless and transparent.
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        textView.string = text
        textView.placeholderString = placeholder
        if autoFocus { textView.focusWhenAttached = true }
        context.coordinator.updateHeight(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! PlaceholderTextView
        context.coordinator.parent = self
        textView.isEditable = context.environment.isEnabled
        textView.placeholderString = placeholder
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.updateHeight(scrollView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoGrowingTextView

        init(_ parent: AutoGrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ obj: Notification) {
            guard let textView = obj.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(textView.enclosingScrollView)
        }

        /// Enter submits; Shift+Enter keeps the default newline behavior.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) {
                return false // newline
            }
            parent.onSubmit?()
            return true
        }

        func updateHeight(_ scrollView: NSScrollView?) {
            guard let scrollView,
                  let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let usedHeight = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height
            let raw = usedHeight + inset * 2 + 4
            let clamped = min(max(raw, parent.minHeight), parent.maxHeight)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.height != clamped else { return }
                self.parent.height = clamped
            }
        }
    }
}

/// NSTextView subclass that draws a placeholder when empty and supports
/// one-shot focus once it has actually been attached to a window.
private final class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }
    var focusWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusWhenAttached, window != nil else { return }
        focusWhenAttached = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? NSFont.systemFont(ofSize: Design.body),
        ]
        let linePadding = textContainer?.lineFragmentPadding ?? 5
        let rect = bounds.insetBy(dx: textContainerInset.width + linePadding, dy: textContainerInset.height)
        (placeholderString as NSString).draw(in: rect, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}