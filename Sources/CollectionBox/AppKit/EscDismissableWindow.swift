import AppKit

/// Shared Esc-dismissal behavior for Pinner's floating panels and windows.
///
/// Every panel advertises "关闭面板 (⎋)" in its close-button tooltip, so Esc
/// must actually work everywhere. Before this existed, 10 panels declared a
/// near-identical `NSPanel` subclass that only toggled `canBecomeKey` and
/// silently dropped the Esc key.
///
/// Three entry points are needed because the key can arrive via any of them:
/// `cancelOperation` (responder chain), `keyDown` (raw key events), and
/// `performKeyEquivalent` (when a nested responder would otherwise swallow it).
class EscDismissableWindow: NSWindow {
    /// Shared so no subclass re-hardcodes the magic number 53.
    static let escapeKeyCode: UInt16 = 53

    /// Escape action. Overridden by EdgeDock's `KeyPanel`, which collapses the
    /// drawer instead of closing the window.
    func handleEscape() {
        close()
    }

    /// Key codes are checked in `keyDown` / `performKeyEquivalent` only;
    /// `cancelOperation` receives a sender, not an event.
    private func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == Self.escapeKeyCode
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    override func keyDown(with event: NSEvent) {
        guard !isEscape(event) else {
            handleEscape()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isEscape(event) {
            handleEscape()
            return true
        }
        // Keep menu shortcuts (⌘C/⌘V/⌘W/⌘Q) alive while the app is `.accessory`
        // (no Dock icon).
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// NSPanel variant. `canBecomeKey` is required so text inputs inside floating
/// panels can take focus; `canBecomeMain` stays false so the panel never
/// becomes the app's main window.
class EscDismissablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func handleEscape() {
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != EscDismissableWindow.escapeKeyCode else {
            handleEscape()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == EscDismissableWindow.escapeKeyCode {
            handleEscape()
            return true
        }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}