// Streaming core: virtual display, ScreenCaptureKit capture, H.264 encoding and TCP transport.
import AppKit
import CoreMedia
import Network
import ScreenCaptureKit
import VideoToolbox

// Stable hash (djb2): same serial number on every connection, so macOS remembers the display arrangement.
func stableHash(_ s: String) -> UInt32 {
    s.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
}

@available(macOS 14.0, *)
final class VirtualScreen {
    let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    // width/height are pixels. On a Retina receiver (hiDPI) macOS uses half of that as the "looks like" size.
    // Fails (instead of crashing) when macOS refuses, e.g. while the previous screen with the same identity is
    // still being removed after a rotation.
    init?(name: String, width: Int, height: Int, sizeMM: CGSize, hiDPI: Bool) {
        guard width > 0, height > 0 else { return nil }
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        desc.sizeInMillimeters = sizeMM
        desc.vendorID = 0xEB15
        desc.productID = 0x0001
        desc.serialNum = stableHash(name)
        let created: CGVirtualDisplay? = CGVirtualDisplay(descriptor: desc)
        guard let created, created.displayID != 0 else { return nil }
        display = created
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        let (mw, mh) = hiDPI ? (width / 2, height / 2) : (width, height)
        settings.modes = [CGVirtualDisplayMode(width: UInt32(mw), height: UInt32(mh), refreshRate: 60)]
        display.applySettings(settings)
    }
}

// What a session needs from its connection to a screen: the native TCP link below, or a browser (WebScreen.swift).
@available(macOS 14.0, *)
protocol ScreenLink: AnyObject {
    var onHello: ((Hello) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var onInput: (([String: Any]) -> Void)? { get set }   // touch gestures (browser screens only)
    var localNetworkDenied: Bool { get }
    var remoteHost: NWEndpoint.Host? { get }
    var sendsPointerInline: Bool { get }   // true: pointer positions go through send(), not the UDP side channel
    func start()
    func stop()
    func sayGoodbye()
    func send(type: UInt8, payload: Data) -> Bool
}

// Wire format: [u32 BE length][u8 type][payload].
@available(macOS 14.0, *)
final class Link: ScreenLink {
    let sendsPointerInline = false
    var onInput: (([String: Any]) -> Void)?
    let conn: NWConnection
    private let q = DispatchQueue(label: "encorescreen.link", qos: .userInteractive)
    private var inflight = 0
    private var closed = false
    var onHello: ((Hello) -> Void)?
    var screenName = ""
    private(set) var localNetworkDenied = false
    var onClose: (() -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo   // Wi-Fi priority (WMM video queue), ahead of bulk traffic
        conn = NWConnection(to: endpoint, using: params)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.readHeader()
            case .waiting:
                if self.conn.currentPath?.unsatisfiedReason == .localNetworkDenied { self.localNetworkDenied = true }
                self.conn.cancel()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: q)
        // A connection blocked by macOS (e.g. Local Network permission) can hang forever: give up after 5 s and retry.
        q.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.conn.state != .ready else { return }
            if self.conn.currentPath?.unsatisfiedReason == .localNetworkDenied { self.localNetworkDenied = true }
            self.conn.cancel()
        }
    }

    func stop() { conn.cancel() }

    var remoteHost: NWEndpoint.Host? {
        if case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint { return host }
        return nil
    }

    // Tell the receiver we are leaving, then close once the message is out (or after 1 s at worst).
    func sayGoodbye() {
        var msg = Data([0, 0, 0, 1])
        msg.append(Proto.bye)
        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in self?.conn.cancel() })
        q.asyncAfter(deadline: .now() + 1) { [weak self] in self?.conn.cancel() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { self.onClose?() }
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, done, err in
            guard let self else { return }
            guard let d, d.count == 4, err == nil else { self.conn.cancel(); return }
            let b = [UInt8](d)
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard len > 0, len < 1 << 20 else { self.conn.cancel(); return }
            self.conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err2 in
                guard let body, body.count == len, err2 == nil else { self.conn.cancel(); return }
                let m = [UInt8](body)
                if m[0] == Proto.hello, m.count >= 9 {
                    func u16(_ i: Int) -> Int { Int(m[i]) << 8 | Int(m[i + 1]) }
                    let (w, h, mw, mh) = (u16(1), u16(3), u16(5), u16(7))
                    let scale = m.count >= 10 ? max(1, Int(m[9])) : 1
                    var id = ""
                    if m.count >= 11 {
                        let n = Int(m[10])
                        if m.count >= 11 + n { id = String(decoding: m[11..<(11 + n)], as: UTF8.self) }
                    }
                    let hello = Hello(width: w, height: h, sizeMM: CGSize(width: mw, height: mh), scale: scale,
                                      deviceID: id.isEmpty ? "legacy-\(self.screenName)" : id, deviceName: self.screenName, key: nil)
                    DispatchQueue.main.async { self.onHello?(hello) }
                }
                if !done { self.readHeader() }
            }
        }
    }

    // Returns false when the send queue overflows (network can't keep up): the frame is dropped.
    func send(type: UInt8, payload: Data) -> Bool {
        if q.sync(execute: { closed || inflight > 3_000_000 }) { return false }
        var msg = Data(capacity: payload.count + 5)
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { msg.append(contentsOf: $0) }
        msg.append(type)
        msg.append(payload)
        let n = msg.count
        q.sync { inflight += n }
        conn.send(content: msg, completion: .contentProcessed { [weak self] _ in
            self?.q.async { self?.inflight -= n }
        })
        return true
    }
}

@available(macOS 14.0, *)
final class Encoder {
    private var session: VTCompressionSession?
    private let link: ScreenLink
    private let lock = NSLock()
    private var _forceKey = true
    var forceKey: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _forceKey }
        set { lock.lock(); _forceKey = newValue; lock.unlock() }
    }

    init?(width: Int, height: Int, bitrate: Int, link: ScreenLink) {
        self.link = link
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let s = session else { log("could not create encoder (\(st))"); return nil }
        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { if let s = session { VTCompressionSessionInvalidate(s) } }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKey = false
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self, status == noErr, let sb else { return }
            self.output(sb)
        }
    }

    private func output(_ sb: CMSampleBuffer) {
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool { isKey = !notSync }
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var payload = Data()
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let p = ptr else { return }
                var l = UInt16(size).bigEndian
                withUnsafeBytes(of: &l) { payload.append(contentsOf: $0) }
                payload.append(p, count: size)
            }
            if !link.send(type: Proto.params, payload: payload) { forceKey = true; return }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(bb))
        data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        if !link.send(type: Proto.frame, payload: data) { forceKey = true }
    }
}

enum Messages {
    static let localNetwork = "macOS is blocking the connection. Turn on Encore Screen in System Settings > Privacy & Security > Local Network."
    static let refused = "This screen was not allowed."
}

// One session = one connection to a receiver, with its own virtual display.
@available(macOS 14.0, *)
final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var name: String
    let link: ScreenLink
    let bitrate: Int
    private var screen: VirtualScreen?
    private var stream: SCStream?
    private var encoder: Encoder?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = Date()
    private var keepAlive: Timer?
    private var cursor: CursorStreamer?
    private(set) var streaming = false
    var onStateChange: (() -> Void)?
    var onActivity: (() -> Void)?   // something moved on the extra screen (new frame or pointer move)
    var onEnd: ((String?) -> Void)?
    // Called once the screen has introduced itself; answer true to start showing the extra screen.
    var approve: ((Hello, @escaping (Bool) -> Void) -> Void)?
    private var endReason: String?

    init(name: String, link: ScreenLink, bitrate: Int) {
        self.name = name
        self.link = link
        self.bitrate = bitrate
    }

    convenience init(name: String, endpoint: NWEndpoint, bitrate: Int) {
        self.init(name: name, link: Link(endpoint: endpoint), bitrate: bitrate)
    }

    func start() {
        (link as? Link)?.screenName = name
        link.onInput = { [weak self] m in
            DispatchQueue.main.async {
                guard let self, let id = self.screen?.displayID else { return }
                TouchInput.handle(m, displayID: id)
            }
        }
        link.onHello = { [weak self] hello in
            guard let self else { return }
            guard let approve = self.approve else { self.begin(hello); return }
            approve(hello) { ok in
                if ok { self.begin(hello) } else { self.endReason = Messages.refused; self.deny() }
            }
        }
        link.onClose = { [weak self] in
            guard let self else { return }
            if self.link.localNetworkDenied { self.endReason = Messages.localNetwork }
            self.teardown()
            self.onEnd?(self.endReason)
        }
        link.start()
    }

    func stop() { link.sayGoodbye() }

    private func deny() {
        _ = link.send(type: Proto.denied, payload: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.link.stop() }
    }

    private func begin(_ hello: Hello) {
        let (width, height, sizeMM, scale) = (hello.width, hello.height, hello.sizeMM, hello.scale)
        if link.sendsPointerInline { name = hello.deviceName }   // browsers introduce themselves ("iPhone (…)")
        // Retina receivers get a HiDPI virtual display (sharp text), capped at 4K to keep Wi-Fi happy.
        let hiDPI = scale >= 2
        let cap = hiDPI ? 3840 : 2560
        var w = width, h = height
        if w > cap { h = h * cap / w; w = cap }
        w &= hiDPI ? ~3 : ~1; h &= hiDPI ? ~3 : ~1
        log("receiver \(name): \(width)x\(height) @\(scale)x, streaming at \(w)x\(h)")
        let mm = sizeMM.width > 0 ? sizeMM : CGSize(width: 476, height: 268)
        createScreen(w: w, h: h, mm: mm, hiDPI: hiDPI, attempt: 0)
    }

    private func createScreen(w: Int, h: Int, mm: CGSize, hiDPI: Bool, attempt: Int) {
        guard let vs = VirtualScreen(name: name, width: w, height: h, sizeMM: mm, hiDPI: hiDPI) else {
            guard attempt < 20 else { endReason = "Could not create the virtual display."; link.stop(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.createScreen(w: w, h: h, mm: mm, hiDPI: hiDPI, attempt: attempt + 1)
            }
            return
        }
        screen = vs
        Task { await self.startCapture(displayID: vs.displayID, width: w, height: h) }
    }

    private func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int) async {
        for _ in 0..<50 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
               let display = content.displays.first(where: { $0.displayID == displayID }) {
                let cfg = SCStreamConfiguration()
                cfg.width = width
                cfg.height = height
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                cfg.showsCursor = false   // the receiver draws the pointer itself (Cursor.swift)
                cfg.queueDepth = 5
                // More pixels need more bits: 25 Mbit/s for 1080p, scaled up to 60 Mbit/s for 4K.
                let rate = min(60_000_000, max(bitrate, bitrate * width * height / (1920 * 1080)))
                guard let enc = Encoder(width: width, height: height, bitrate: rate, link: link) else {
                    endReason = "Video encoder unavailable."; link.stop(); return
                }
                encoder = enc
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "encorescreen.capture", qos: .userInteractive))
                    try await s.startCapture()
                } catch {
                    endReason = "Cannot capture the screen: allow Encore Screen in System Settings > Privacy & Security > Screen Recording."
                    log("capture failed: \(error.localizedDescription)")
                    link.stop(); return
                }
                await MainActor.run {
                    self.stream = s
                    self.streaming = true
                    let cs = CursorStreamer(displayID: displayID, link: self.link)
                    cs.onMove = { [weak self] in self?.onActivity?() }
                    cs.start()
                    self.cursor = cs
                    // Static screen: resend the last frame after a drop so the receiver never stays stuck on a broken picture.
                    var ticks = 0
                    self.keepAlive = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        ticks += 1
                        // Heartbeat: lets the receiver notice a dead connection even on a still screen.
                        if ticks % 2 == 0 { _ = self.link.send(type: Proto.ping, payload: Data()) }
                        guard let enc = self.encoder, enc.forceKey, let pb = self.lastFrame,
                              Date().timeIntervalSince(self.lastFrameTime) > 0.3 else { return }
                        enc.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
                    }
                    self.onStateChange?()
                }
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        endReason = "Could not create the virtual display."
        link.stop()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = pb
        lastFrameTime = Date()
        // Only real movement counts (a window, a scroll, a video), not a blinking text caret or a ticking clock:
        // above 1% of the screen changed in this frame.
        if let rects = atts.first?[.dirtyRects] as? [NSDictionary] {
            let area = rects.compactMap { CGRect(dictionaryRepresentation: $0) }.reduce(0) { $0 + $1.width * $1.height }
            let total = CGFloat(CVPixelBufferGetWidth(pb) * CVPixelBufferGetHeight(pb))
            if total > 0, area / total > 0.01 { onActivity?() }
        } else {
            onActivity?()
        }
        encoder?.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
        link.stop()
    }

    private func teardown() {
        keepAlive?.invalidate(); keepAlive = nil
        cursor?.stop(); cursor = nil
        stream?.stopCapture { _ in }
        stream = nil
        encoder = nil
        lastFrame = nil
        screen = nil   // releasing the virtual display removes it: windows move back to the main screen
        streaming = false
    }
}
