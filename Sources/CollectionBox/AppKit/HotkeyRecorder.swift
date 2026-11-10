import AppKit
import SwiftUI

/// Shared "press a key combination" recorder panel used by every feature's
/// hotkey settings menu.
///
/// Styled like every other Pinner panel: glass window, `PanelTitleBar` header,
/// circular close button, no traffic lights. The key monitor is torn down on
/// every close path (close button, Esc, or a saved combo) — a monitor that
/// outlives its window keeps swallowing key events app-wide.
enum HotkeyRecorder {
    static func present(title: String, onSave: @escaping (HotkeyCombo) -> Void) {
        let window = RecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()

        let model = RecorderModel()

        let hv = NSHostingView(rootView: HotkeyRecorderView(
            title: title,
            model: model,
            onClose: { [weak window] in window?.close() }
        ))
        hv.frame = window.contentView?.bounds ?? .zero
        hv.autoresizingMask = [.width, .height]
        window.contentView = hv

        // A local monitor rather than a key equivalent: the panel has no title
        // bar and nothing worth making first responder.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == EscDismissableWindow.escapeKeyCode {
                window.close()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty {
                model.hint = "请先按住修饰键"
                return event
            }
            let carbonMods = carbonModifiers(from: event.modifierFlags)
            let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            model.display = combo.displayString
            onSave(combo)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.close() }
            return nil
        }
        window.installMonitor(monitor)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Recorder panel state. Deliberately not `@MainActor`: `present` is called from
/// non-isolated menu/action code, and every mutation below already happens on
/// the main thread (AppKit key monitor + close notification).
private final class RecorderModel: ObservableObject {
    @Published var hint = "请按下快捷键组合"
    @Published var display = "等待按键…"
}

/// Panel that guarantees the key monitor and the close observer die with the
/// window, whichever path closed it.
private final class RecorderPanel: EscDismissablePanel {
    private var monitor: Any?
    private var closeObserver: NSObjectProtocol?

    func installMonitor(_ monitor: Any) {
        self.monitor = monitor
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in self?.teardown() }
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    deinit { teardown() }
}

private struct HotkeyRecorderView: View {
    let title: String
    @ObservedObject var model: RecorderModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitleBar(symbolName: "command", title: title, onClose: onClose)

            VStack(spacing: 6) {
                Text(model.hint)
                    .font(.system(size: Design.body))
                    .foregroundColor(.secondary)
                Text(model.display)
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .frame(width: 300)
        .liquidGlassBackground()
    }
}
