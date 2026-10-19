// Brand colors and the menu bar icon (the mascot, drawn as a template image).
import AppKit
import SwiftUI

enum Brand {
    static let orange = Color(red: 1.0, green: 0.70, blue: 0.28)   // #FFB347
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.42)    // #FF6B6B

    // Smiling screen, 18 pt. Filled when streaming.
    static func menuBarIcon(active: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 17, height: 12), xRadius: 3.2, yRadius: 3.2)
            body.lineWidth = 1.6
            NSColor.black.set()
            if active { body.fill() } else { body.stroke() }
            NSBezierPath(roundedRect: NSRect(x: 7, y: 0.8, width: 6, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(rect: NSRect(x: 9.2, y: 2, width: 1.6, height: 2.6)).fill()
            // When filled, eyes and smile are punched out so the template image stays readable.
            if active { NSGraphicsContext.current?.compositingOperation = .destinationOut }
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 10.6, width: 2, height: 2.4)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.7, y: 10.6, width: 2, height: 2.4)).fill()
            let smile = NSBezierPath()
            smile.appendArc(withCenter: NSPoint(x: 10, y: 9.6), radius: 2.6, startAngle: 210, endAngle: 330)
            smile.lineWidth = 1.3
            smile.lineCapStyle = .round
            smile.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "SpareScreen"
        return img
    }
}
