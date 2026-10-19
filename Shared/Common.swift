// Shared by both modes. Everything here runs on macOS 10.15 Catalina.
import AppKit

func log(_ s: String) { NSLog("[Encore Screen] %@", s) }

enum Proto {
    static let serviceType = "_encorescreen._tcp"
    static let videoPort: UInt16 = 7777
    static let cursorPort: UInt16 = 7778
    static let params: UInt8 = 1       // main → screen: SPS + PPS
    static let frame: UInt8 = 2        // main → screen: H.264 frame (AVCC)
    static let hello: UInt8 = 3        // screen → main: [u16 w px][u16 h px][u16 w mm][u16 h mm][u8 scale]
    static let bye: UInt8 = 4          // main → screen: streaming stopped on purpose
    static let ping: UInt8 = 5         // main → screen: heartbeat, every second
    static let cursorShape: UInt8 = 7  // main → screen: pointer image (position goes over UDP, see Cursor.swift)
}

// Which role this Mac plays. Stored per Mac, chosen in the welcome window.
enum AppMode: String {
    case main     // "This is my main Mac": creates the extra display and sends it
    case screen   // "Make this an extra screen": shows the picture full screen

    static var current: AppMode? {
        get { UserDefaults.standard.string(forKey: "mode").flatMap(AppMode.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "mode") }
    }

    static var mainModeSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }
}

enum Brand {
    static let orange = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.28, alpha: 1)   // #FFB347
    static let coral = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)    // #FF6B6B
}

// Open at login through a LaunchAgent (works on every macOS version we support).
enum LoginItem {
    static let label = "app.encorescreen"
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

// Keeps the Mac and its display awake while Encore Screen runs in screen mode.
enum KeepAwake {
    private static var token: NSObjectProtocol?
    static var preferred: Bool {
        get { UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepAwake"); apply() }
    }

    static func apply() {
        if preferred, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                                          reason: "Encore Screen keeps this screen ready")
        } else if !preferred, let t = token {
            ProcessInfo.processInfo.endActivity(t)
            token = nil
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

// MARK: - Small AppKit building blocks shared by the welcome and screen windows

final class GradientHeader: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Brand.coral, ending: Brand.orange)?.draw(in: bounds, angle: -30)
    }
}

// Small breathing dot next to a "waiting" status.
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

func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let t = NSTextField(wrappingLabelWithString: s)
    t.font = .systemFont(ofSize: size, weight: weight)
    t.textColor = color
    t.isSelectable = false
    return t
}

// Gradient header with the mascot, a title and a tagline.
func brandHeader(title: String, tagline: String) -> NSView {
    let header = GradientHeader()
    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.translatesAutoresizingMaskIntoConstraints = false
    let t = label(title, size: 26, weight: .bold, color: .white)
    t.alignment = .center
    let sub = label(tagline, size: 13, weight: .medium, color: NSColor.white.withAlphaComponent(0.92))
    sub.alignment = .center
    let stack = NSStackView(views: [icon, t, sub])
    stack.orientation = .vertical
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(stack)
    header.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        icon.widthAnchor.constraint(equalToConstant: 96), icon.heightAnchor.constraint(equalToConstant: 96),
        stack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor, constant: 20),
        stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 36),
        stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -22),
    ])
    return header
}

func numberedRow(_ n: Int, _ title: String, _ detail: String) -> NSView {
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

func linkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.isBordered = false
    b.attributedTitle = NSAttributedString(string: title, attributes: [
        .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12),
        .underlineStyle: NSUnderlineStyle.single.rawValue,
    ])
    return b
}
