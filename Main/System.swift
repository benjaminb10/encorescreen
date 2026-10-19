// System integration: AirDrop (awdl0 interface), screen capture and local network permissions.
import AppKit
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
    // Registers SpareScreen in System Settings and shows the system prompt (which has its own
    // "Open System Settings" button). If macOS already showed it once, go straight to the settings pane.
    static func request() {
        if !CGRequestScreenCaptureAccess() && UserDefaults.standard.bool(forKey: "screenPromptShown") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        UserDefaults.standard.set(true, forKey: "screenPromptShown")
    }
}

enum LocalNetwork {
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }
}
