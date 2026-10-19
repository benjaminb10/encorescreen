// Touch control: gestures made on a browser screen (tap, scroll, long press, pinch) are replayed on the Mac,
// at the touched spot of the extra screen. Clicks move the pointer there and put it back right after,
// so the user's mouse stays where it was. Needs the Accessibility permission (asked on first use).
import AppKit
import ApplicationServices

enum TouchInput {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "touchControl") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "touchControl") }
    }

    private static var asked = false

    // True when we may post events. Asks once with the system prompt otherwise.
    static func allowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !asked {
            asked = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    // x, y: 0…1 on the extra screen. Messages come from the page as JSON: {"t": "tap" | "double" | "right" |
    // "scroll" | "zoom", "x", "y", "dx", "dy", "dir"}.
    static func handle(_ m: [String: Any], displayID: CGDirectDisplayID) {
        debug("input \(m["t"] ?? "?") enabled=\(enabled) trusted=\(AXIsProcessTrusted())")
        guard enabled, allowed() else { return }
        let b = CGDisplayBounds(displayID)
        let x = (m["x"] as? Double ?? 0.5), y = (m["y"] as? Double ?? 0.5)
        let point = CGPoint(x: b.minX + CGFloat(x) * b.width, y: b.minY + CGFloat(y) * b.height)
        switch m["t"] as? String {
        case "tap": click(at: point, count: 1)
        case "double": click(at: point, count: 2)
        case "right": click(at: point, count: 1, right: true)
        case "scroll":
            // dx, dy in points of the extra screen; positive dy = content follows the finger downwards.
            let dy = Int32((m["dy"] as? Double ?? 0).rounded()), dx = Int32((m["dx"] as? Double ?? 0).rounded())
            withPointer(at: point, restore: false) {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
                e?.location = point
                e?.post(tap: .cghidEventTap)
            }
        case "text":
            // Characters typed on the phone's keyboard, sent as text (accents and emoji included).
            guard let str = m["s"] as? String, !str.isEmpty else { return }
            let utf16 = Array(str.utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e?.post(tap: .cghidEventTap)
            }
        case "key":
            let codes: [String: CGKeyCode] = ["Backspace": 51, "Enter": 36, "Tab": 48, "Escape": 53,
                                              "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126]
            guard let k = m["k"] as? String, let code = codes[k] else { return }
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
        case "zoom":
            // Pinch: the standard zoom shortcut of the app under the finger (⌘+ / ⌘-).
            withPointer(at: point, restore: true) {
                let key: CGKeyCode = (m["dir"] as? String) == "in" ? 24 : 27   // "=" / "-"
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                    e?.flags = .maskCommand
                    e?.post(tap: .cghidEventTap)
                }
            }
        default: break
        }
    }

    private static func click(at p: CGPoint, count: Int, right: Bool = false) {
        withPointer(at: p, restore: true) {
            let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
            for n in 1...count {
                for type in [down, up] {
                    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: right ? .right : .left)
                    e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                    e?.post(tap: .cghidEventTap)
                }
            }
        }
    }

    // Briefly moves the pointer to p (events go to the window under it), then puts it back if asked.
    private static var restoreWork: DispatchWorkItem?
    private static var homePoint: CGPoint?
    private static func withPointer(at p: CGPoint, restore: Bool, _ body: () -> Void) {
        let current = CGEvent(source: nil)?.location ?? p
        // Remember where the user's pointer really was (not a spot we warped to for a previous gesture).
        if homePoint == nil { homePoint = current }
        CGWarpMouseCursorPosition(p)
        body()
        restoreWork?.cancel()
        let work = DispatchWorkItem {
            if let home = homePoint { CGWarpMouseCursorPosition(home) }
            homePoint = nil
        }
        restoreWork = work
        // Scrolls keep the pointer in place for a moment so momentum keeps going to the same window.
        DispatchQueue.main.asyncAfter(deadline: .now() + (restore ? 0.05 : 0.6), execute: work)
    }
}

// Where the focused text field is, if it is on the given extra screen (0…1 coordinates), so the page can offer
// its keyboard. Needs the Accessibility permission; returns nil otherwise.
func focusedTextField(on displayID: CGDirectDisplayID) -> CGRect? {
    guard AXIsProcessTrusted() else { return nil }
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
    let element = el as! AXUIElement
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    let role = roleRef as? String ?? ""
    var editable: CFTypeRef?
    AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
    let textRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    guard textRoles.contains(role) || (editable as? Bool) == true else { return nil }
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
    var pos = CGPoint.zero, size = CGSize.zero
    if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
    if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
    let b = CGDisplayBounds(displayID)
    let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    guard b.contains(center) else { return nil }
    return CGRect(x: (pos.x - b.minX) / b.width, y: (pos.y - b.minY) / b.height, width: size.width / b.width, height: size.height / b.height)
}

// Temporary diagnostics (written to /tmp/encorescreen-debug.log).
func debug(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/encorescreen-debug.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { try? line.write(toFile: "/tmp/encorescreen-debug.log", atomically: true, encoding: .utf8) }
}
