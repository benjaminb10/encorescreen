import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    func applicationDidFinishLaunching(_ n: Notification) {
        controller.launch()
        if CommandLine.arguments.contains("--request-screen") { ScreenPermission.request() }
    }
    // Relaunching the app (Finder, Spotlight) reopens the assistant, useful when the notch hides the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showOnboarding()
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
