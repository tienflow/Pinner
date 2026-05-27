import Carbon
import AppKit

/// Convert NSEvent.ModifierFlags to Carbon modifier mask
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
}

/// Records the current hotkey state for display in menus.
struct HotkeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon modifiers

    var displayString: String {
        var s = ""
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        s += keyString(forKey: Int(keyCode))
        return s
    }

    private func keyString(forKey keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"; case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"; case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"; case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."; case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "Space"; case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"; case kVK_Delete: return "⌫"
        case kVK_Tab: return "Tab"; case kVK_ANSI_Keypad0: return "0"
        case kVK_ANSI_Keypad1: return "1"; case kVK_ANSI_Keypad2: return "2"
        case kVK_ANSI_Keypad3: return "3"; case kVK_ANSI_Keypad4: return "4"
        case kVK_ANSI_Keypad5: return "5"; case kVK_ANSI_Keypad6: return "6"
        case kVK_ANSI_Keypad7: return "7"; case kVK_ANSI_Keypad8: return "8"
        case kVK_ANSI_Keypad9: return "9"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: return "?"
        }
    }
}

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkeyTriggered: (() -> Void)?

    /// Default hotkey: Cmd+Shift+P
    static let defaultCombo = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Currently registered hotkey combo.
    var currentCombo: HotkeyCombo {
        let code = UserDefaults.standard.integer(forKey: "CollectionBox.hotkeyCode")
        let mods = UserDefaults.standard.integer(forKey: "CollectionBox.hotkeyMods")
        if code == 0 && mods == 0 { return Self.defaultCombo }
        return HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    func register() {
        unregister()
        let combo = currentCombo

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // Install Carbon event handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &eventType, selfPtr, &handlerRef)

        // Register the hotkey
        var hotKeyID = EventHotKeyID(signature: OSType(0x504E_4E52), id: 1) // "PNNR"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
    }

    func save(combo: HotkeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: "CollectionBox.hotkeyCode")
        UserDefaults.standard.set(Int(combo.modifiers), forKey: "CollectionBox.hotkeyMods")
        register()
    }

    func clear() {
        UserDefaults.standard.set(Int(Self.defaultCombo.keyCode), forKey: "CollectionBox.hotkeyCode")
        UserDefaults.standard.set(Int(Self.defaultCombo.modifiers), forKey: "CollectionBox.hotkeyMods")
        register()
    }

    fileprivate func handleEvent() {
        onHotkeyTriggered?()
    }
}

private func hotkeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleEvent()
    return noErr
}
