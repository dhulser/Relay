import Carbon
import AppKit

/// A system-wide keyboard shortcut, registered through Carbon's hot-key API,
/// which is still the sanctioned way to get one without an Accessibility
/// grant. Fires on the main thread.
///
/// Two shapes: a plain shortcut that fires once per press (start/stop), and a
/// hold key that reports the press and the release separately (push to
/// talk). Carbon delivers both as hot-key events; every registered hot key
/// shares the one event stream, so each instance checks the ID is its own.
final class GlobalHotKey {

    /// ⌃⌥⌘R: three modifiers so it collides with nothing common, R for Relay.
    static let defaultKeyCode = UInt32(kVK_ANSI_R)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let defaultDescription = "⌃⌥⌘R"

    private static let signature = OSType(0x524C5952) /* "RLYR" */
    private static var nextID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: (() -> Void)?
    private let id: UInt32

    convenience init(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
                     modifiers: UInt32 = GlobalHotKey.defaultModifiers,
                     action: @escaping () -> Void) {
        self.init(keyCode: keyCode, modifiers: modifiers, onPress: action, onRelease: nil)
    }

    init(keyCode: UInt32, modifiers: UInt32,
         onPress: @escaping () -> Void, onRelease: (() -> Void)?) {
        self.onPress = onPress
        self.onRelease = onRelease
        id = Self.nextID
        Self.nextID += 1

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.signature == GlobalHotKey.signature, hotKeyID.id == owner.id else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                if pressed { owner.onPress() } else { owner.onRelease?() }
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPointer, &handler)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            Log.error(.app, "Could not register the global shortcut (\(status))")
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
