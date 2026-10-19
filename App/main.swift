// One app, two roles. The welcome window asks which one this Mac plays, then the matching controller starts.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chooser: ModeChooser?
    private var mainController: AnyObject?      // Controller (main mode, macOS 14+)
    private var screenController: ScreenController?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        route()
    }

    private func route() {
        switch AppMode.current {
        case .main? where AppMode.mainModeSupported: startMain()
        case .screen?: startScreen()
        default: showChooser()
        }
    }

    private func showChooser() {
        NSApp.setActivationPolicy(.regular)
        let c = ModeChooser()
        c.onChoose = { [weak self] mode in
            AppMode.current = mode
            self?.chooser?.window.close()
            self?.chooser = nil
            self?.route()
        }
        chooser = c
        c.show()
    }

    private func startMain() {
        guard #available(macOS 14.0, *) else { return }
        NSApp.setActivationPolicy(.accessory)
        let c = Controller()
        c.onSwitchMode = { [weak self] in self?.switchMode() }
        mainController = c
        c.launch()
    }

    private func startScreen() {
        NSApp.setActivationPolicy(.regular)
        let s = ScreenController()
        s.onSwitchMode = { [weak self] in self?.switchMode() }
        screenController = s
        s.start()
    }

    // Forget the role and relaunch, so the welcome window shows up again.
    @objc func switchMode() {
        AppMode.current = nil
        UserDefaults.standard.removeObject(forKey: "onboarded")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let s = screenController { s.reopen() }
        else if #available(macOS 14.0, *), let c = mainController as? Controller { c.showOnboarding() }
        else { chooser?.show() }
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        m.addItem(withTitle: "About SpareScreen", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Switch Role…", action: #selector(switchMode), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Hide SpareScreen", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        m.addItem(withTitle: "Quit SpareScreen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
