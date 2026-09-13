import Carbon
import AppKit

/// A system-wide keyboard shortcut, registered through Carbon's hot-key API,
/// which is still the sanctioned way to get one without an Accessibility
/// grant. Fires on the main thread.
final class GlobalHotKey {

    /// ⌃⌥⌘R: three modifiers so it collides with nothing common, R for Relay.
    static let defaultKeyCode = UInt32(kVK_ANSI_R)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let defaultDescription = "⌃⌥⌘R"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
         modifiers: UInt32 = GlobalHotKey.defaultModifiers,
         action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { owner.action() }
            return noErr
        }, 1, &eventType, selfPointer, &handler)

        let id = EventHotKeyID(signature: OSType(0x524C5952) /* "RLYR" */, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            Log.error(.app, "Could not register the global shortcut (\(status))")
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
