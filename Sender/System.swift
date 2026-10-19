// System integration: AirDrop (awdl0 interface), login item, screen capture permission.
import AppKit
import ScreenCaptureKit
import ServiceManagement

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

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { log("login item: \(error.localizedDescription)") }
    }
}

enum ScreenPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    // Touching ScreenCaptureKit registers the app in System Settings and shows the system prompt.
    // Settings only opens if access is still missing a moment later, with SpareScreen already listed.
    static func request() {
        log("requesting screen capture, preflight=\(granted)")
        let r = CGRequestScreenCaptureAccess()
        log("CGRequestScreenCaptureAccess -> \(r)")
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, e in
            log("SCShareableContent -> \(c != nil) \(e?.localizedDescription ?? "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !granted {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }
}
