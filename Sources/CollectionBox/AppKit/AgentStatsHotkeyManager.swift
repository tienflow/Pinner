import AppKit
import Carbon

/// Configurable hotkeys for agents without a legacy default binding.
/// No default is registered, so adding an agent does not take over another app's shortcut.
final class AgentStatsHotkeyManager {
    private let keyPrefix: String
    private let eventID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkeyTriggered: (() -> Void)?
    /// Outcome of the latest registered attempt: nil = no binding registered.
    private(set) var lastRegistrationSucceeded: Bool?

    init(keyPrefix: String, eventID: UInt32) {
        self.keyPrefix = keyPrefix
        self.eventID = eventID
    }

    var currentCombo: HotkeyCombo? {
        guard let code = UserDefaults.standard.object(forKey: keyPrefix + "Code") as? Int,
              let mods = UserDefaults.standard.object(forKey: keyPrefix + "Mods") as? Int else { return nil }
        return HotkeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    func register() {
        unregister()
        lastRegistrationSucceeded = nil
        guard let combo = currentCombo else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<AgentStatsHotkeyManager>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x504E_4153), id.id == manager.eventID else {
                return OSStatus(eventNotHandledErr)
            }
            manager.onHotkeyTriggered?()
            return noErr
        }, 1, &type, context, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x504E_4153), id: eventID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        lastRegistrationSucceeded = status == noErr
        if status != noErr {
            HotkeyRegistrationNotifier.notifyFailure(combo: combo)
        }
    }

    func save(combo: HotkeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: keyPrefix + "Code")
        UserDefaults.standard.set(Int(combo.modifiers), forKey: keyPrefix + "Mods")
        register()
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: keyPrefix + "Code")
        UserDefaults.standard.removeObject(forKey: keyPrefix + "Mods")
        unregister()
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
