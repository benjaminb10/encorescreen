// Screen mode ("Make this an extra screen"): advertises this Mac on the network (Bonjour), receives the
// H.264 stream and shows it full screen, with the pointer drawn locally. Runs on macOS 10.15 Catalina and later.
import AVFoundation
import Cocoa
import CoreMedia
import Network

final class Receiver {
    private var listener: NWListener?
    private var conn: NWConnection?
    private var format: CMVideoFormatDescription?
    private let q = DispatchQueue(label: "encorescreen.recv", qos: .userInteractive)
    private var lastReceived = Date()
    private var watchdog: DispatchSourceTimer?
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onSample: ((CMSampleBuffer) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onCursorShape: ((CGImage, CGPoint, CGSize) -> Void)?
    var onCursorMove: ((CGFloat, CGFloat, Bool) -> Void)?
    private var cursorListener: NWListener?
    private var cursorSeq: UInt16 = 0

    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: Proto.videoPort)!) else {
            log("port 7777 unavailable"); return
        }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Proto.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { st in log("listener: \(st)") }
        l.start(queue: q)
        listener = l
        // The sender pings every second. Silence for 4 s means it is gone (sleep, Wi-Fi drop): go back home.
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let c = self.conn, Date().timeIntervalSince(self.lastReceived) > 4 else { return }
            log("no data for 4 s, closing")
            c.cancel()
        }
        t.resume()
        watchdog = t
        startCursorChannel()
    }

    // Pointer positions arrive as small UDP datagrams, see Cursor.swift on the sender.
    private func startCursorChannel() {
        guard let l = try? NWListener(using: .udp, on: NWEndpoint.Port(rawValue: Proto.cursorPort)!) else { log("port 7778 unavailable"); return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self?.q ?? .main)
            self?.readCursor(c)
        }
        l.start(queue: q)
        cursorListener = l
    }

    private func readCursor(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, err == nil else { return }
            if let d = data, d.count >= 8 {
                let b = [UInt8](d)
                let seq = UInt16(b[1]) << 8 | UInt16(b[2])
                // Ignore datagrams that arrive out of order.
                if b[0] == 6, Int16(bitPattern: seq &- self.cursorSeq) > 0 || self.cursorSeq == 0 {
                    self.cursorSeq = seq
                    let x = CGFloat(UInt16(b[3]) << 8 | UInt16(b[4])) / 65535
                    let y = CGFloat(UInt16(b[5]) << 8 | UInt16(b[6])) / 65535
                    let visible = b[7] == 1
                    DispatchQueue.main.async { self.onCursorMove?(x, y, visible) }
                }
            }
            self.readCursor(c)
        }
    }

    func closeConnection() { q.async { self.conn?.cancel() } }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        format = nil
        cursorSeq = 0
        lastReceived = Date()
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c else { return }
            switch st {
            case .ready:
                self.sendHello(c)
                let who: String
                if case let .hostPort(host, _) = c.endpoint { who = "\(host)" } else { who = "\(c.endpoint)" }
                DispatchQueue.main.async { self.onConnect?(who) }
                self.readHeader(c)
            case .failed, .cancelled:
                if self.conn === c {
                    self.conn = nil
                    DispatchQueue.main.async { self.onDisconnect?() }
                }
            default: break
            }
        }
        c.start(queue: q)
    }

    // Announces the screen size: [u16 width px][u16 height px][u16 width mm][u16 height mm].
    private func sendHello(_ c: NWConnection) {
        var w = 1920, h = 1080, mw = 0, mh = 0, scale = 1
        DispatchQueue.main.sync {
            if let s = NSScreen.main {
                scale = Int(s.backingScaleFactor.rounded())
                w = Int(s.frame.width * s.backingScaleFactor)
                h = Int(s.frame.height * s.backingScaleFactor)
                if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
                    mw = Int(mm.width); mh = Int(mm.height)
                }
            }
        }
        var body: [UInt8] = [3]
        for v in [w, h, mw, mh] { body += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        body.append(UInt8(scale))
        let id = Array(DeviceIdentity.id.utf8)
        body.append(UInt8(id.count))
        body += id
        let len = body.count
        let msg = [UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)] + body
        c.send(content: Data(msg), completion: .idempotent)
    }

    private func readHeader(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, err in
            guard let self, let data, data.count == 4, err == nil else { c.cancel(); return }
            let b = [UInt8](data)
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard len > 0, len < 64 << 20 else { c.cancel(); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err2 in
                guard let body, body.count == len, err2 == nil else { c.cancel(); return }
                let p = Data(body)
                self.lastReceived = Date()
                if p[0] == 4 { c.cancel(); return }   // sender stopped streaming
                self.handle(type: p[0], payload: p.subdata(in: 1..<p.count))
                self.readHeader(c)
            }
        }
    }

    private func handle(type: UInt8, payload p: Data) {
        if type == 1 {
            // [u16 SPS size][SPS][u16 PPS size][PPS]
            let b = [UInt8](p)
            guard b.count > 4 else { return }
            let spsLen = Int(b[0]) << 8 | Int(b[1])
            let o = 2 + spsLen
            guard b.count >= o + 2 else { return }
            let ppsLen = Int(b[o]) << 8 | Int(b[o + 1])
            guard b.count >= o + 2 + ppsLen else { return }
            let sps = Array(b[2..<o]), pps = Array(b[(o + 2)..<(o + 2 + ppsLen)])
            var fd: CMVideoFormatDescription?
            sps.withUnsafeBufferPointer { s in
                pps.withUnsafeBufferPointer { pp in
                    let ptrs = [s.baseAddress!, pp.baseAddress!]
                    let sizes = [sps.count, pps.count]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                        nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                }
            }
            if let fd, fd != format {
                let dim = CMVideoFormatDescriptionGetDimensions(fd)
                DispatchQueue.main.async { self.onVideoSize?(CGSize(width: Int(dim.width), height: Int(dim.height))) }
            }
            format = fd
        } else if type == 7, p.count > 8 {
            let b = [UInt8](p)
            func v(_ i: Int) -> CGFloat { CGFloat(UInt16(b[i]) << 8 | UInt16(b[i + 1])) / 16 }
            let hot = CGPoint(x: v(0), y: v(2)), size = CGSize(width: v(4), height: v(6))
            if let src = CGImageSourceCreateWithData(p.subdata(in: 8..<p.count) as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                DispatchQueue.main.async { self.onCursorShape?(img, hot, size) }
            }
        } else if type == 2, let fd = format {
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: p.count, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: p.count,
                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
            guard let block = bb else { return }
            p.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: p.count) }
            var sb: CMSampleBuffer?
            var size = p.count
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: 1,
                                      sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                      sampleSizeArray: &size, sampleBufferOut: &sb)
            guard let sample = sb else { return }
            if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            DispatchQueue.main.async { self.onSample?(sample) }
        }
    }
}

final class ScreenController: NSObject {
    var onSwitchMode: (() -> Void)?
    var home: NSWindow!
    var full: NSWindow!
    var layer = AVSampleBufferDisplayLayer()
    let cursorLayer = CALayer()
    var videoSize = CGSize(width: 1920, height: 1080)
    var cursorHot = CGPoint.zero
    var cursorSize = CGSize(width: 17, height: 23)
    var status: NSTextField!
    let receiver = Receiver()
    var activity: NSObjectProtocol?

    func start() {
        if !UserDefaults.standard.bool(forKey: "screenConfigured") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "screenConfigured")
        }
        KeepAwake.apply()
        buildHome()
        buildFullscreen()
        receiver.onConnect = { [weak self] who in self?.status.stringValue = "Connecting…"; self?.enterFullscreen() }
        receiver.onDisconnect = { [weak self] in self?.leaveFullscreen() }
        receiver.onVideoSize = { [weak self] size in self?.videoSize = size }
        receiver.onCursorShape = { [weak self] img, hot, size in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.cursorLayer.contents = img
            self.cursorHot = hot
            self.cursorSize = size
            CATransaction.commit()
        }
        receiver.onCursorMove = { [weak self] x, y, visible in self?.moveCursor(x: x, y: y, visible: visible) }
        receiver.onSample = { [weak self] s in
            guard let self else { return }
            if self.layer.status == .failed { self.layer.flush() }
            self.layer.enqueue(s)
        }
        receiver.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, self?.full.isVisible == true { self?.receiver.closeConnection(); return nil }
            return e
        }
    }

    func reopen() {
        if !full.isVisible { home.makeKeyAndOrderFront(nil) }
    }

    private func buildHome() {
        home = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        home.title = "Encore Screen"
        home.titlebarAppearsTransparent = true
        home.titleVisibility = .hidden
        home.isReleasedWhenClosed = false
        let name = Host.current().localizedName ?? "this Mac"

        let header = brandHeader(title: "Ready to be your extra screen", tagline: "Leave this window open. Your main Mac does the rest.")
        status = label("Waiting for your main Mac…", size: 13, weight: .semibold, color: Brand.coral)
        let statusRow = NSStackView(views: [PulseDot(), status])
        statusRow.spacing = 8

        let login = NSButton(checkboxWithTitle: "Open Encore Screen at login", target: self, action: #selector(toggleLogin(_:)))
        login.state = LoginItem.enabled ? .on : .off
        let awake = NSButton(checkboxWithTitle: "Keep this Mac awake, so it's always ready", target: self, action: #selector(toggleAwake(_:)))
        awake.state = KeepAwake.preferred ? .on : .off
        let info = label("This Mac: \(name)" + (localIPv4().map { " · \($0)" } ?? ""), size: 11, color: .tertiaryLabelColor)
        let switchButton = NSButton(title: "Use this Mac as the main Mac instead", target: self, action: #selector(switchRole))
        switchButton.bezelStyle = .rounded
        switchButton.controlSize = .small
        let switchRole = NSStackView(views: [label("Is this the Mac you work on?", size: 12, color: .secondaryLabelColor), switchButton])
        switchRole.spacing = 8
        switchRole.isHidden = !AppMode.mainModeSupported   // an older Mac can only be an extra screen

        let body = NSStackView(views: [
            numberedRow(1, "Open Encore Screen on your main Mac", "Same app, same Wi-Fi. Choose \u{201C}This is my main Mac\u{201D}."),
            numberedRow(2, "Pick \u{201C}\(name)\u{201D}", "From the smiling screen in your main Mac's menu bar."),
            numberedRow(3, "That's it", "This screen fills up with your extra desktop. Press Esc to come back here."),
            statusRow, login, awake, info, switchRole,
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.setCustomSpacing(24, after: body.arrangedSubviews[2])
        body.setCustomSpacing(20, after: statusRow)
        body.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        let root = NSStackView(views: [header, body])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        home.contentView = root
        home.center()
        home.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildFullscreen() {
        let frame = NSScreen.main?.frame ?? .zero
        full = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        full.backgroundColor = .black
        full.level = .mainMenu + 1
        full.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        cursorLayer.zPosition = 10
        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        view.layer?.addSublayer(cursorLayer)
        full.contentView = view
    }

    private func enterFullscreen() {
        if let f = NSScreen.main?.frame { full.setFrame(f, display: true) }
        home.orderOut(nil)
        full.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .latencyCritical], reason: "Encore Screen")
    }

    // Where the video sits inside the full screen window (aspect fit), in layer coordinates (origin bottom-left).
    private var videoRect: CGRect {
        let bounds = layer.bounds
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let k = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * k, h = videoSize.height * k
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private func moveCursor(x: CGFloat, y: CGFloat, visible: Bool) {
        let r = videoRect
        let k = r.width / videoSize.width   // stream pixels are points on the sender's virtual display
        let px = r.minX + x * r.width, py = r.maxY - y * r.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        cursorLayer.frame = CGRect(x: px - cursorHot.x * k, y: py - (cursorSize.height - cursorHot.y) * k,
                                   width: cursorSize.width * k, height: cursorSize.height * k)
        CATransaction.commit()
    }

    private func leaveFullscreen() {
        layer.flushAndRemoveImage()
        cursorLayer.isHidden = true
        full.orderOut(nil)
        NSApp.presentationOptions = []
        NSCursor.unhide()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        status.stringValue = "Waiting for your main Mac…"
        home.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLogin(_ sender: NSButton) { LoginItem.set(sender.state == .on) }
    @objc private func toggleAwake(_ sender: NSButton) { KeepAwake.preferred = sender.state == .on }
    @objc private func switchRole() { onSwitchMode?() }
}
