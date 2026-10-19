// SpareScreen Receiver: advertises itself on the network (Bonjour), receives the H.264 stream and shows it full screen.
// Runs on macOS 10.15 Catalina and later. Press Esc while streaming to go back to the home window.
import AVFoundation
import Cocoa
import CoreMedia
import Network

let serviceType = "_sparescreen._tcp"

func log(_ s: String) { NSLog("[SpareScreen Receiver] %@", s) }

final class Receiver {
    private var listener: NWListener?
    private var conn: NWConnection?
    private var format: CMVideoFormatDescription?
    private let q = DispatchQueue(label: "sparescreen.recv", qos: .userInteractive)
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onSample: ((CMSampleBuffer) -> Void)?

    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 7777) else {
            log("port 7777 unavailable"); return
        }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: serviceType)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { st in log("listener: \(st)") }
        l.start(queue: q)
        listener = l
    }

    func closeConnection() { q.async { self.conn?.cancel() } }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c
        format = nil
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
        var w = 1920, h = 1080, mw = 0, mh = 0
        DispatchQueue.main.sync {
            if let s = NSScreen.main {
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
            format = fd
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

// Open at login through a LaunchAgent (works on Catalina).
enum LoginItem {
    static let label = "app.sparescreen.receiver"
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

func localIPv4() -> String? {
    var addr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addr) == 0, let first = addr else { return nil }
    defer { freeifaddrs(addr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = p.pointee
        guard a.ifa_addr.pointee.sa_family == UInt8(AF_INET), let name = String(validatingUTF8: a.ifa_name),
              name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(a.ifa_addr, socklen_t(a.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }
    return nil
}

enum Brand {
    static let orange = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.28, alpha: 1)   // #FFB347
    static let coral = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)    // #FF6B6B
}

final class GradientHeader: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Brand.coral, ending: Brand.orange)?.draw(in: bounds, angle: -30)
    }
}

// Small breathing dot next to the "waiting" status.
final class PulseDot: NSView {
    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        wantsLayer = true
        layer?.backgroundColor = Brand.coral.cgColor
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 10).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0.25; a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
        layer?.add(a, forKey: "pulse")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var home: NSWindow!
    var full: NSWindow!
    var layer = AVSampleBufferDisplayLayer()
    var status: NSTextField!
    let receiver = Receiver()
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildHome()
        buildFullscreen()
        if !UserDefaults.standard.bool(forKey: "configured") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "configured")
        }
        receiver.onConnect = { [weak self] who in self?.status.stringValue = "Connecting…"; self?.enterFullscreen() }
        receiver.onDisconnect = { [weak self] in self?.leaveFullscreen() }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !full.isVisible { home.makeKeyAndOrderFront(nil) }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "Quit SpareScreen Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        return t
    }

    private func stepRow(_ n: Int, _ title: String, _ detail: String) -> NSView {
        let badge = NSTextField(labelWithString: "\(n)")
        badge.font = .systemFont(ofSize: 15, weight: .bold)
        badge.textColor = Brand.coral
        badge.alignment = .center
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.backgroundColor = Brand.coral.withAlphaComponent(0.15).cgColor
        circle.layer?.cornerRadius = 16
        circle.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(badge)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 32), circle.heightAnchor.constraint(equalToConstant: 32),
            badge.centerXAnchor.constraint(equalTo: circle.centerXAnchor), badge.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        let text = NSStackView(views: [label(title, size: 13, weight: .semibold), label(detail, size: 12, color: .secondaryLabelColor)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [circle, text])
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func buildHome() {
        home = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        home.title = "SpareScreen Receiver"
        home.titlebarAppearsTransparent = true
        home.titleVisibility = .hidden
        home.isReleasedWhenClosed = false
        let name = Host.current().localizedName ?? "this Mac"

        let header = GradientHeader()
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = label("SpareScreen Receiver", size: 26, weight: .bold, color: .white)
        title.alignment = .center
        let subtitle = label("This screen is about to become an extra display.", size: 13, weight: .medium, color: NSColor.white.withAlphaComponent(0.92))
        subtitle.alignment = .center
        let headerStack = NSStackView(views: [icon, title, subtitle])
        headerStack.orientation = .vertical
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 104), icon.heightAnchor.constraint(equalToConstant: 104),
            headerStack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            headerStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 36),
            headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -22),
        ])

        status = label("Waiting for your Mac…", size: 13, weight: .semibold, color: Brand.coral)
        let dot = PulseDot()
        let statusRow = NSStackView(views: [dot, status])
        statusRow.spacing = 8
        let check = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggleLogin(_:)))
        check.state = LoginItem.enabled || !UserDefaults.standard.bool(forKey: "configured") ? .on : .off
        let info = label("This device: \(name)" + (localIPv4().map { " · \($0)" } ?? ""), size: 11, color: .tertiaryLabelColor)

        let body = NSStackView(views: [
            stepRow(1, "Open SpareScreen on your Mac", "The free app for your main Mac, on the same Wi-Fi."),
            stepRow(2, "Pick \u{201C}\(name)\u{201D}", "Click the smiling screen in your Mac's menu bar."),
            stepRow(3, "That's it", "This screen goes full screen. Press Esc to come back here."),
            statusRow, check, info,
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        body.setCustomSpacing(24, after: body.arrangedSubviews[2])
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
        full.contentView = view
    }

    private func enterFullscreen() {
        if let f = NSScreen.main?.frame { full.setFrame(f, display: true) }
        home.orderOut(nil)
        full.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .latencyCritical], reason: "SpareScreen")
    }

    private func leaveFullscreen() {
        layer.flushAndRemoveImage()
        full.orderOut(nil)
        NSApp.presentationOptions = []
        NSCursor.unhide()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        status.stringValue = "Waiting for your Mac…"
        home.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLogin(_ sender: NSButton) { LoginItem.set(sender.state == .on) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
