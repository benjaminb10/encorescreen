// Global shortcut ⌃⌥⌘S to start or stop streaming, even when the menu bar icon is hidden.
// Carbon hot keys need no Accessibility permission.
import Carbon

enum Hotkey {
    private static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5350_5343), id: 1) // 'SPSC'
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
