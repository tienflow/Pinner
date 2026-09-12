import AppKit

/// Shared "press a key combination" recorder panel used by every feature's
/// hotkey settings menu.
enum HotkeyRecorder {
    static func present(title: String, onSave: @escaping (HotkeyCombo) -> Void) {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                             styleMask: [.titled, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .floating
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        let label = NSTextField(labelWithString: "请按下快捷键组合")
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 80, width: 260, height: 20)

        let keyLabel = NSTextField(labelWithString: "等待按键...")
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        keyLabel.alignment = .center
        keyLabel.frame = NSRect(x: 20, y: 30, width: 260, height: 40)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(keyLabel)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                if let m = monitor { NSEvent.removeMonitor(m) }
                window.close()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.isEmpty {
                keyLabel.stringValue = "请先按住修饰键"
                return event
            }
            let carbonMods = carbonModifiers(from: event.modifierFlags)
            let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            keyLabel.stringValue = combo.displayString
            if let m = monitor { NSEvent.removeMonitor(m) }
            onSave(combo)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.close() }
            return nil
        }
    }
}
