// System integration: AirDrop (awdl0 interface), screen capture and local network permissions.
import AppKit
import AVFoundation
import Network
import ScreenCaptureKit

// AirDrop makes Wi-Fi hop channels several times per second, which causes stutter.
// We take its interface (awdl0) down while streaming and bring it back up afterwards.
// To avoid a password prompt every time, onboarding installs a sudo rule limited to these two commands.
enum AirDrop {
    static let sudoersPath = "/etc/sudoers.d/sparescreen"

    static var helperInstalled: Bool { FileManager.default.fileExists(atPath: sudoersPath) }

    @discardableResult
    static func installHelper() -> Bool {
        let user = NSUserName()
        let rule = "\(user) ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down, /sbin/ifconfig awdl0 up"
        let tmp = "/tmp/sparescreen-sudoers"
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
    // Settings only opens if access is still missing a moment later, with SpareScreen already listed.
    private static var probe: AVCaptureSession?

    // macOS only lists an app under Screen Recording once it has really tried to capture.
    // So we ask, then start a one-second capture of the main display: that registers SpareScreen
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

// Experimental: talk to the screen over the direct Wi-Fi link AirDrop uses (AWDL), like Sidecar does,
// instead of going through the router. AirDrop stays on, and both Macs don't even need the same network.
enum Transport {
    static var direct: Bool {
        get { UserDefaults.standard.bool(forKey: "directLink") }
        set { UserDefaults.standard.set(newValue, forKey: "directLink") }
    }
    private static var monitor: NWPathMonitor?
    private(set) static var routerInterfaces: [NWInterface] = []

    // Remember the regular network interfaces (Wi-Fi, Ethernet) so a direct connection can avoid them.
    static func startMonitoring() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in routerInterfaces = path.availableInterfaces }
        m.start(queue: .main)
        monitor = m
    }

    static func apply(_ p: NWParameters) -> NWParameters {
        guard direct else { return p }
        p.includePeerToPeer = true
        p.prohibitedInterfaces = routerInterfaces
        return p
    }
}
