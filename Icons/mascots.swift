// Mascot icon concepts. Usage: swift Icons/mascots.swift <output dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}
func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

func canvas(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func background(_ c1: UInt32, _ c2: UInt32) -> NSBezierPath {
    let shape = rr(100, 100, 824, 824, 185)
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.25); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
    rgb(c1).setFill(); shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [rgb(c1), rgb(c2)])!.draw(in: shape, angle: -70)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!.draw(in: shape, angle: -90)
    return shape
}

// Friendly face: two eyes with highlights, smile, blush.
func face(cx: CGFloat, cy: CGFloat, scale k: CGFloat, ink: NSColor, wink: Bool = false, sleepy: Bool = false) {
    let ex = 62 * k, ey = 18 * k
    for side: CGFloat in [-1, 1] {
        let x = cx + side * ex
        if (wink && side == 1) || sleepy {
            let p = NSBezierPath()
            p.appendArc(withCenter: NSPoint(x: x, y: cy + ey + 6 * k), radius: 22 * k, startAngle: 200, endAngle: 340)
            p.lineWidth = 11 * k; p.lineCapStyle = .round; ink.setStroke(); p.stroke()
        } else {
            ink.setFill(); oval(x, cy + ey, 20 * k, 26 * k).fill()
            NSColor.white.setFill(); oval(x + 7 * k, cy + ey + 9 * k, 7 * k, 8 * k).fill()
        }
    }
    let m = NSBezierPath()
    m.appendArc(withCenter: NSPoint(x: cx, y: cy - 22 * k), radius: 38 * k, startAngle: 205, endAngle: 335)
    m.lineWidth = 11 * k; m.lineCapStyle = .round; ink.setStroke(); m.stroke()
    rgb(0xFF7A9A, 0.55).setFill()
    oval(cx - 112 * k, cy - 18 * k, 24 * k, 14 * k).fill()
    oval(cx + 112 * k, cy - 18 * k, 24 * k, 14 * k).fill()
}

func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: NSColor) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx, y: cy + r))
    p.curve(to: NSPoint(x: cx + r, y: cy), controlPoint1: NSPoint(x: cx + r * 0.15, y: cy + r * 0.15), controlPoint2: NSPoint(x: cx + r * 0.15, y: cy + r * 0.15))
    p.curve(to: NSPoint(x: cx, y: cy - r), controlPoint1: NSPoint(x: cx + r * 0.15, y: cy - r * 0.15), controlPoint2: NSPoint(x: cx + r * 0.15, y: cy - r * 0.15))
    p.curve(to: NSPoint(x: cx - r, y: cy), controlPoint1: NSPoint(x: cx - r * 0.15, y: cy - r * 0.15), controlPoint2: NSPoint(x: cx - r * 0.15, y: cy - r * 0.15))
    p.curve(to: NSPoint(x: cx, y: cy + r), controlPoint1: NSPoint(x: cx - r * 0.15, y: cy + r * 0.15), controlPoint2: NSPoint(x: cx - r * 0.15, y: cy + r * 0.15))
    color.setFill(); p.fill()
}

func soft(_ path: NSBezierPath, _ fill: NSColor) {
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.18); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -8); sh.set()
    fill.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

let ink = rgb(0x1E1B3A)

// A: a happy monitor buddy with Wi-Fi "antennae" on a warm background.
func buddy(receiver: Bool) -> NSBitmapImageRep { canvas {
    _ = receiver ? background(0xFF6B6B, 0xFFB347) : background(0xFFB347, 0xFF6B6B)
    // stand
    soft(rr(462, 250, 100, 120, 16), .white)
    soft(rr(392, 232, 240, 40, 20), .white)
    // body
    soft(rr(232, 340, 560, 420, 80), .white)
    rgb(0xFFF4E6).setFill(); rr(272, 380, 480, 340, 50).fill()
    face(cx: 512, cy: 545, scale: 1.35, ink: ink)
    // waves on top
    for (i, r) in [CGFloat(70), 125].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 512, y: 770), radius: r, startAngle: 50, endAngle: 130)
        arc.lineWidth = 26; arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.75).setStroke(); arc.stroke()
    }
} }
let a = buddy(receiver: false)

// B: duo. A laptop buddy hands a sparkle to a bigger screen buddy.
func duo(receiver: Bool) -> NSBitmapImageRep { canvas {
    _ = receiver ? background(0x38BDF8, 0x7C6CFF) : background(0x7C6CFF, 0x38BDF8)
    // big screen (the old Mac) on the right
    soft(rr(640, 300, 70, 90, 12), .white)
    soft(rr(590, 285, 170, 30, 15), .white)
    soft(rr(450, 380, 400, 320, 64), .white)
    rgb(0xEEF2FF).setFill(); rr(480, 410, 340, 260, 40).fill()
    face(cx: 650, cy: 530, scale: 1.0, ink: ink)
    // laptop on the left
    soft(rr(170, 250, 330, 30, 15), .white)
    soft(rr(200, 275, 270, 200, 40), .white)
    rgb(0xEEF2FF).setFill(); rr(222, 297, 226, 156, 26).fill()
    face(cx: 335, cy: 365, scale: 0.62, ink: ink, wink: true)
    sparkle(470, 640, 52, .white)
    sparkle(400, 720, 26, NSColor.white.withAlphaComponent(0.8))
} }
let b = duo(receiver: false)

// C: "second life". A retro beige Mac buddy, refreshed, with a sparkle.
let c = canvas {
    _ = background(0x34D399, 0x0EA5E9)
    // classic compact Mac body
    soft(rr(300, 220, 424, 560, 70), rgb(0xFFF8EC))
    rgb(0xEADFCB).setFill(); rr(300, 220, 424, 120, 70).fill()
    rgb(0xFFF8EC).setFill(); NSBezierPath(rect: NSRect(x: 300, y: 300, width: 424, height: 60)).fill()
    // floppy slot
    rgb(0xBFB29C).setFill(); rr(520, 280, 150, 18, 9).fill()
    // screen
    rgb(0x2A2550).setFill(); rr(350, 420, 324, 300, 46).fill()
    face(cx: 512, cy: 555, scale: 0.95, ink: rgb(0x8EF6C8))
    sparkle(735, 760, 62, .white)
    sparkle(290, 815, 30, NSColor.white.withAlphaComponent(0.85))
}

for (name, rep) in [("concept-A-copain", a), ("concept-B-duo", b), ("concept-C-seconde-vie", c),
                    ("SpareScreen-1024", a), ("SpareScreenReceiver-1024", buddy(receiver: true))] {
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
}
print("ok")
