// Streaming core: virtual display, ScreenCaptureKit capture, H.264 encoding and TCP transport.
import AppKit
import CoreMedia
import Network
import ScreenCaptureKit
import VideoToolbox

enum Proto {
    static let serviceType = "_sparescreen._tcp"
    static let params: UInt8 = 1   // sender → receiver: SPS + PPS
    static let frame: UInt8 = 2    // sender → receiver: H.264 frame (AVCC)
    static let hello: UInt8 = 3    // receiver → sender: screen size
}

func log(_ s: String) { NSLog("[SpareScreen] %@", s) }

// Stable hash (djb2): same serial number on every connection, so macOS remembers the display arrangement.
func stableHash(_ s: String) -> UInt32 {
    s.utf8.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ UInt32($1) }
}

final class VirtualScreen {
    let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    init(name: String, width: Int, height: Int, sizeMM: CGSize) {
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        desc.sizeInMillimeters = sizeMM
        desc.vendorID = 0xEB15
        desc.productID = 0x0001
        desc.serialNum = stableHash(name)
        display = CGVirtualDisplay(descriptor: desc)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
        display.applySettings(settings)
    }
}

// Wire format: [u32 BE length][u8 type][payload].
final class Link {
    let conn: NWConnection
    private let q = DispatchQueue(label: "sparescreen.link", qos: .userInteractive)
    private var inflight = 0
    private var closed = false
    var onHello: ((Int, Int, CGSize) -> Void)?
    var onClose: (() -> Void)?

    init(endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        conn = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: self.readHeader()
            case .waiting: self.conn.cancel()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: q)
    }

    func stop() { conn.cancel() }

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
                    DispatchQueue.main.async { self.onHello?(w, h, CGSize(width: mw, height: mh)) }
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

final class Encoder {
    private var session: VTCompressionSession?
    private let link: Link
    private let lock = NSLock()
    private var _forceKey = true
    var forceKey: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _forceKey }
        set { lock.lock(); _forceKey = newValue; lock.unlock() }
    }

    init?(width: Int, height: Int, bitrate: Int, link: Link) {
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

// One session = one connection to a receiver, with its own virtual display.
final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    let name: String
    let link: Link
    let bitrate: Int
    private var screen: VirtualScreen?
    private var stream: SCStream?
    private var encoder: Encoder?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = Date()
    private var keepAlive: Timer?
    private(set) var streaming = false
    var onStateChange: (() -> Void)?
    var onEnd: ((String?) -> Void)?
    private var endReason: String?

    init(name: String, endpoint: NWEndpoint, bitrate: Int) {
        self.name = name
        self.link = Link(endpoint: endpoint)
        self.bitrate = bitrate
    }

    func start() {
        link.onHello = { [weak self] w, h, mm in self?.begin(width: w, height: h, sizeMM: mm) }
        link.onClose = { [weak self] in
            guard let self else { return }
            self.teardown()
            self.onEnd?(self.endReason)
        }
        link.start()
    }

    func stop() { link.stop() }

    private func begin(width: Int, height: Int, sizeMM: CGSize) {
        var w = width, h = height
        if w > 2560 { h = h * 2560 / w; w = 2560 }
        w &= ~1; h &= ~1
        log("receiver \(name): \(width)x\(height), streaming at \(w)x\(h)")
        let mm = sizeMM.width > 0 ? sizeMM : CGSize(width: 476, height: 268)
        let vs = VirtualScreen(name: name, width: w, height: h, sizeMM: mm)
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
                cfg.showsCursor = true
                cfg.queueDepth = 5
                guard let enc = Encoder(width: width, height: height, bitrate: bitrate, link: link) else {
                    endReason = "Video encoder unavailable."; link.stop(); return
                }
                encoder = enc
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
                do {
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sparescreen.capture", qos: .userInteractive))
                    try await s.startCapture()
                } catch {
                    endReason = "Cannot capture the screen: allow SpareScreen in System Settings > Privacy & Security > Screen Recording."
                    log("capture failed: \(error.localizedDescription)")
                    link.stop(); return
                }
                await MainActor.run {
                    self.stream = s
                    self.streaming = true
                    // Static screen: resend the last frame after a drop so the receiver never stays stuck on a broken picture.
                    self.keepAlive = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        guard let self, let enc = self.encoder, enc.forceKey, let pb = self.lastFrame,
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
        encoder?.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription)")
        link.stop()
    }

    private func teardown() {
        keepAlive?.invalidate(); keepAlive = nil
        stream?.stopCapture { _ in }
        stream = nil
        encoder = nil
        lastFrame = nil
        screen = nil   // releasing the virtual display removes it: windows move back to the main screen
        streaming = false
    }
}
