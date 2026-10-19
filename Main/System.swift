// System integration: AirDrop (awdl0 interface), screen capture and local network permissions.
import AppKit
import AVFoundation
import Network
import ScreenCaptureKit

// AirDrop makes Wi-Fi hop channels several times per second, which causes stutter.
// We take its interface (awdl0) down while streaming and bring it back up afterwards.
// To avoid a password prompt every time, onboarding installs a sudo rule limited to these two commands.
enum AirDrop {
    static let sudoersPath = "/etc/sudoers.d/encorescreen"

    // The rule only allows "ifconfig awdl0 up/down", so the one installed under the app's former name works too.
    static let legacySudoersPath = "/etc/sudoers.d/sparescreen"
    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath) || FileManager.default.fileExists(atPath: legacySudoersPath)
    }

    @discardableResult
    static func installHelper() -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up"
        let tmp = "/tmp/encorescreen-sudoers"
        let shell = "printf '%s\\n' '\(rule)' > \(tmp) && /usr/sbin/visudo -cf \(tmp) && "
            + "/usr/bin/install -m 0440 -o root -g wheel \(tmp) \(sudoersPath); rm -f \(tmp)"
        return runAsAdmin(shell)
    }

    // True when the awdl0 interface is up (AirDrop / Continuity active).
    static var isActive: Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next })
            where String(cString: p.pointee.ifa_name) == "awdl0" && (Int32(p.pointee.ifa_flags) & IFF_UP) != 0 { return true }
        return false
    }

    static func uninstallHelper() { runAsAdmin("rm -f \(sudoersPath)") }

    static func set(enabled: Bool) {
        let arg = enabled ? "up" : "down"
        if helperInstalled {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "/sbin/ifconfig", "awdl0", arg]
            try? p.run()
            p.waitUntilExit()
        } else if !enabled {
            runAsAdmin("/sbin/ifconfig awdl0 down")
        }
    }

    @discardableResult
    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        return err == nil
    }
}

@available(macOS 14.0, *)
enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    // Touching ScreenCaptureKit registers the app in System Settings and shows the system prompt.
    // Settings only opens if access is still missing a moment later, with Encore Screen already listed.
    private static var probe: AVCaptureSession?

    // macOS only lists an app under Screen Recording once it has really tried to capture.
    // So we ask, then start a one-second capture of the main display: that registers Encore Screen
    // in System Settings (switched off, ready to be turned on) and shows the system prompt.
    static func request() {
        let askedBefore = UserDefaults.standard.bool(forKey: "screenPromptShown")
        UserDefaults.standard.set(true, forKey: "screenPromptShown")
        CGRequestScreenCaptureAccess()
        let session = AVCaptureSession()
        if let input = AVCaptureScreenInput(displayID: CGMainDisplayID()), session.canAddInput(input) {
            session.addInput(input)
            session.startRunning()
            probe = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe?.stopRunning(); probe = nil }
        }
        // Open the list right away, next to the system prompt, so the user sees where to switch it on.
        DispatchQueue.main.asyncAfter(deadline: .now() + (askedBefore ? 0 : 2)) {
            guard !granted else { return }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}

enum LocalNetwork {
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }
}

// Screens the user allowed once. A new device (or one that changed identity) has to be allowed on this Mac.
enum ApprovedDevices {
    private static let key = "approvedDevices"
    static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func contains(_ id: String) -> Bool { !id.isEmpty && all[id] != nil }
    static func add(_ id: String, name: String) { guard !id.isEmpty else { return }; all[id] = name }
    static func forgetAll() { all = [:] }

    // Asks on this Mac, once per device. Remembered afterwards.
    static func ask(_ hello: Hello, completion: @escaping (Bool) -> Void) {
        if contains(hello.deviceID) { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Show your extra screen on \u{201C}\(hello.deviceName)\u{201D}?"
        alert.informativeText = "A device on your network wants to become your extra screen. It will see everything you put on that screen. Only allow devices you own."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok { add(hello.deviceID, name: hello.deviceName) }
        completion(ok)
    }
}

// Encryption for browser screens. When a certificate is installed (issued for this Mac by encorescreen.com,
// see docs/https.md), the page and the stream are served over HTTPS / WSS. Without one, plain HTTP / WS.
enum TLSIdentity {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Encore Screen")
    }
    static var p12: URL { folder.appendingPathComponent("tls.p12") }
    // Host name the certificate was issued for, e.g. 192-168-1-15.a1b2c3.encorescreen.com.
    static var hostName: String? { try? String(contentsOf: folder.appendingPathComponent("tls-host.txt")).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func load() -> sec_identity_t? {
        guard let data = try? Data(contentsOf: p12) else { return nil }
        let password = (try? String(contentsOf: folder.appendingPathComponent("tls-password.txt")).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return sec_identity_create(identity as! SecIdentity)
    }

    static func parameters(_ identity: sec_identity_t?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let identity else { return NWParameters(tls: nil, tcp: tcp) }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return NWParameters(tls: tls, tcp: tcp)
    }
}
