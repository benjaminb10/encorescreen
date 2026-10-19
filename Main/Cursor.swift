// Streams the mouse pointer separately from the video, so it moves with network latency only
// instead of waiting for capture, encoding and decoding. The receiver draws it on top of the picture.
//   position: UDP datagrams, 120 per second  [u8 6][u16 seq][u16 x][u16 y][u8 visible]  (x, y normalized to 0…65535)
//   shape:    TCP message type 7 when it changes  [u16 hotX*16][u16 hotY*16][u16 w*16][u16 h*16][PNG]  (stream pixels)
import AppKit
import Network

@available(macOS 14.0, *)
final class CursorStreamer {
    private let displayID: CGDirectDisplayID
    private let link: Link
    private let q = DispatchQueue(label: "encorescreen.cursor", qos: .userInteractive)
    private var udp: NWConnection?
    private var timer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var last: (UInt16, UInt16, Bool)?
    private var ticks = 0
    private var shapeHash = 0
    var onMove: (() -> Void)?

    init(displayID: CGDirectDisplayID, link: Link) {
        self.displayID = displayID
        self.link = link
    }

    func start() {
        guard let host = link.remoteHost else { log("cursor: unknown receiver address"); return }
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice   // highest Wi-Fi priority (WMM voice queue): tiny, time-critical packets
        let c = NWConnection(host: host, port: NWEndpoint.Port(rawValue: Proto.cursorPort)!, using: params)
        c.start(queue: q)
        udp = c
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
        udp?.cancel(); udp = nil
    }

    private func tick() {
        ticks += 1
        if ticks % 6 == 0 { DispatchQueue.main.async { [weak self] in self?.sendShapeIfChanged() } }
        guard let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(displayID)
        let visible = b.contains(loc)
        func norm(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(65535, (v * 65535).rounded()))) }
        let x = norm((loc.x - b.minX) / b.width), y = norm((loc.y - b.minY) / b.height)
        // Unchanged position: still resend 4 times a second, so a lost datagram never leaves the pointer stale.
        if let l = last, l.0 == x, l.1 == y, l.2 == visible, ticks % 30 != 0 { return }
        if visible, let l = last, l.0 != x || l.1 != y { onMove?() }
        last = (x, y, visible)
        seq &+= 1
        let pkt: [UInt8] = [6, UInt8(seq >> 8), UInt8(seq & 0xFF), UInt8(x >> 8), UInt8(x & 0xFF),
                            UInt8(y >> 8), UInt8(y & 0xFF), visible ? 1 : 0]
        udp?.send(content: Data(pkt), completion: .idempotent)
    }

    private func sendShapeIfChanged() {
        guard let cursor = NSCursor.currentSystem, let tiff = cursor.image.tiffRepresentation else { return }
        let h = tiff.hashValue
        guard h != shapeHash, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        // Points → stream pixels (2 on a HiDPI virtual display), so the receiver needs no extra info.
        let b = CGDisplayBounds(displayID)
        let px = b.width > 0 ? CGFloat(CGDisplayPixelsWide(displayID)) / b.width : 1
        let size = CGSize(width: cursor.image.size.width * px, height: cursor.image.size.height * px)
        let hot = CGPoint(x: cursor.hotSpot.x * px, y: cursor.hotSpot.y * px)
        var p = Data()
        for v in [hot.x, hot.y, size.width, size.height] {
            let u = UInt16(max(0, min(65535, (v * 16).rounded())))
            p.append(contentsOf: [UInt8(u >> 8), UInt8(u & 0xFF)])
        }
        p.append(png)
        if link.send(type: Proto.cursorShape, payload: p) { shapeHash = h }
    }
}
