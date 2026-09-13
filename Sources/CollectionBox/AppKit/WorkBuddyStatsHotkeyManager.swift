import Carbon
import AppKit

final class WorkBuddyStatsHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkeyTriggered: (() -> Void)?

    /// Default hotkey: Cmd+Shift+W
    static let defaultCombo = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_W),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    var currentCombo: HotkeyCombo {
        let code = UserDefaults.standard.integer(forKey: "CollectionBox.workbuddyStatsHotkeyCode")
        let mods = UserDefaults.standard.integer(forKey: "CollectionBox.workbuddyStatsHotkeyMods")
        if code == 0 && mods == 0 { return Self.defaultCombo }
        return HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    func register() {
        unregister()
        let combo = currentCombo

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), workbuddyStatsHotkeyCallback, 1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x504E_4757), id: 5) // "PNGW"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = handlerRef { RemoveEventHandler(ref); handlerRef = nil }
    }

    func save(combo: HotkeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: "CollectionBox.workbuddyStatsHotkeyCode")
        UserDefaults.standard.set(Int(combo.modifiers), forKey: "CollectionBox.workbuddyStatsHotkeyMods")
        register()
    }

    func clear() {
        UserDefaults.standard.set(Int(Self.defaultCombo.keyCode), forKey: "CollectionBox.workbuddyStatsHotkeyCode")
        UserDefaults.standard.set(Int(Self.defaultCombo.modifiers), forKey: "CollectionBox.workbuddyStatsHotkeyMods")
        register()
    }

    fileprivate func handleEvent() {
        onHotkeyTriggered?()
    }
}

private func workbuddyStatsHotkeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard hotKeyID.signature == OSType(0x504E_4757), hotKeyID.id == 5 else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<WorkBuddyStatsHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleEvent()
    return noErr
}
