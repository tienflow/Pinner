import Carbon
import AppKit

final class CodexStatsHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkeyTriggered: (() -> Void)?

    /// Default hotkey: Cmd+Shift+I
    static let defaultCombo = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_I),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    var currentCombo: HotkeyCombo {
        let code = UserDefaults.standard.integer(forKey: "CollectionBox.codexStatsHotkeyCode")
        let mods = UserDefaults.standard.integer(forKey: "CollectionBox.codexStatsHotkeyMods")
        if code == 0 && mods == 0 { return Self.defaultCombo }
        return HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    func register() {
        unregister()
        let combo = currentCombo

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), codexStatsHotkeyCallback, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x504E_4358), id: 3) // "PNCX"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
    }

    func save(combo: HotkeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: "CollectionBox.codexStatsHotkeyCode")
        UserDefaults.standard.set(Int(combo.modifiers), forKey: "CollectionBox.codexStatsHotkeyMods")
        register()
    }

    func clear() {
        UserDefaults.standard.set(Int(Self.defaultCombo.keyCode), forKey: "CollectionBox.codexStatsHotkeyCode")
        UserDefaults.standard.set(Int(Self.defaultCombo.modifiers), forKey: "CollectionBox.codexStatsHotkeyMods")
        register()
    }

    fileprivate func handleEvent() {
        onHotkeyTriggered?()
    }
}

private func codexStatsHotkeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard hotKeyID.signature == OSType(0x504E_4358), hotKeyID.id == 3 else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<CodexStatsHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleEvent()
    return noErr
}
