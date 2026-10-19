// Menu bar app: receiver discovery (Bonjour), connection, settings and onboarding.
import AppKit
import Network
import SwiftUI

@available(macOS 14.0, *)
final class Controller: NSObject, ObservableObject, NSMenuDelegate {
    @Published var receivers: [String: NWEndpoint] = [:]
    @Published var activeName: String?
    @Published var lastError: String?
    @Published var localNetworkDenied = false
    @Published var localNetworkOK = false
    @Published var streaming = false
    private var probe: NWConnection?
    private var probeTimer: Timer?
    @Published var browsing = false
    var onSwitchMode: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var browser: NWBrowser?
    private var session: Session?
    private var userStopped = false
    private var airDropGuard: Timer?
    let web = WebScreenServer()
    private var certificateTimer: Timer?
    private var qrWindow: NSWindow?
    private var lastActivity = Date.distantPast
    private var airDropPaused = false
    private var onboardingWindow: NSWindow?
    private let defaults = UserDefaults.standard

    var lastReceiver: String? {
        get { defaults.string(forKey: "lastReceiver") }
        set { defaults.set(newValue, forKey: "lastReceiver") }
    }
    var cutAirDrop: Bool {
        get { defaults.object(forKey: "cutAirDrop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cutAirDrop") }
    }
    // Smart mode: AirDrop is only paused while something moves on the extra screen, and comes back
    // 2 seconds after it stops. Off: AirDrop stays paused for the whole session.
    var smartAirDrop: Bool {
        get { defaults.object(forKey: "smartAirDrop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "smartAirDrop") }
    }
    var bitrate: Int { defaults.integer(forKey: "bitrate") > 0 ? defaults.integer(forKey: "bitrate") : 25_000_000 }

    func launch() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        statusItem.autosaveName = "EncoreScreenStatusItem"
        Hotkey.register { [weak self] in self?.toggleStreaming() }
        web.bitrate = bitrate
        web.onActivity = { [weak self] in self?.noteActivity() }
        web.onChange = { [weak self] in self?.updateIcon(); self?.armAirDropGuard() }
        web.start()
        refreshCertificate()
        certificateTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refreshCertificate() }
        startBrowsing()
        if !defaults.bool(forKey: "onboarded") { showOnboarding() }
        if !defaults.bool(forKey: "mainConfigured") {
            LoginItem.set(true)
            defaults.set(true, forKey: "mainConfigured")
        }
    }

    // MARK: Discovery

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: Proto.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint { found[name] = r.endpoint }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.receivers = found
                self.probeLocalNetwork()
                self.autoConnect()
            }
        }
        // Bonjour reports a policy error when macOS denies Local Network access (kDNSServiceErr_PolicyDenied).
        b.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                switch st {
                case .ready: self.browsing = true
                case .waiting(let e), .failed(let e):
                    if case let .dns(code) = e, code == -65570 { self.localNetworkDenied = true }
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    // Seeing a screen over Bonjour doesn't prove we may connect to it: macOS can still block the
    // connection (Local Network). Open a UDP flow to the screen (nothing is sent, so the screen doesn't react)
    // and look at the path: ready means allowed, "localNetworkDenied" means blocked. Retry until allowed.
    private func probeLocalNetwork() {
        guard !localNetworkOK, probe == nil, let endpoint = receivers.values.first else { return }
        let c = NWConnection(to: endpoint, using: .udp)
        probe = c
        c.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self, self.probe === c else { return }
                switch st {
                case .ready:
                    self.localNetworkOK = true
                    self.localNetworkDenied = false
                    c.cancel(); self.probe = nil
                    self.probeTimer?.invalidate(); self.probeTimer = nil
                case .waiting, .failed:
                    if c.currentPath?.unsatisfiedReason == .localNetworkDenied { self.localNetworkDenied = true }
                    c.cancel(); self.probe = nil
                default: break
                }
            }
        }
        c.start(queue: .main)
        if probeTimer == nil {
            probeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.probeLocalNetwork() }
        }
    }

    private func autoConnect() {
        // Never start capturing before Screen Recording is granted: each attempt would pop the system prompt again.
        guard ScreenPermission.granted, session == nil, !userStopped, defaults.bool(forKey: "onboarded") || lastReceiver != nil,
              let name = lastReceiver, receivers[name] != nil else { return }
        connect(name)
    }

    // MARK: Connection

    func connect(_ name: String) {
        guard let endpoint = receivers[name] else { return }
        guard ScreenPermission.granted else {
            lastError = "Allow Screen Recording first (Setup Assistant, step 1)."
            showOnboarding()
            return
        }
        session?.stop()
        userStopped = false
        lastError = nil
        lastReceiver = name
        if cutAirDrop && !smartAirDrop { pauseAirDrop() }
        let s = Session(name: name, endpoint: endpoint, bitrate: bitrate)
        s.approve = { hello, done in ApprovedDevices.ask(hello, completion: done) }
        s.onActivity = { [weak self] in self?.noteActivity() }
        s.onStateChange = { [weak self] in
            self?.updateIcon()
            if s.streaming { self?.localNetworkOK = true; self?.localNetworkDenied = false }
        }
        s.onEnd = { [weak self, weak s] reason in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            self.activeName = nil
            self.airDropGuard?.invalidate()
            self.airDropGuard = nil
            self.armAirDropGuard()
            if let reason { self.lastError = reason }
            if reason == Messages.localNetwork { self.localNetworkDenied = true }
            if reason == Messages.refused { self.userStopped = true }   // don't reconnect to a refused screen
            if self.cutAirDrop && !self.anyScreenOn { self.resumeAirDrop() }
            self.updateIcon()
            // Unexpected drop (sleep, Wi-Fi): retry while the receiver is still advertised.
            // Also keep retrying while macOS blocks Local Network: it works as soon as the user allows it.
            if !self.userStopped && (reason == nil || reason == Messages.localNetwork) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (reason == nil ? 2 : 5)) { self.autoConnect() }
            }
        }
        session = s
        activeName = name
        s.start()
        armAirDropGuard()
        updateIcon()
    }

    private var anyScreenOn: Bool { session != nil || !web.sessions.isEmpty }

    // Gets (or renews) this Mac's HTTPS certificate and keeps its name pointing to the current local address.
    private func refreshCertificate() {
        DirectCertificate.refresh { [weak self] changed in if changed { self?.web.reloadTLS() } }
    }

    // Tip jar. Goes through the website so the payment page can change without a new app version.
    @objc private func openSupport() { NSWorkspace.shared.open(URL(string: "https://encorescreen.com/support")!) }

    private func noteActivity() {
        DispatchQueue.main.async {
            self.lastActivity = Date()
            if self.cutAirDrop && !self.airDropPaused { self.pauseAirDrop() }
        }
    }

    // Keeps AirDrop in the right state: paused while the screen moves (or for the whole session if smart mode
    // is off), back on after 2 s of stillness. Also re-pauses it if macOS turns it back on by itself.
    private func armAirDropGuard() {
        guard anyScreenOn else {
            airDropGuard?.invalidate(); airDropGuard = nil
            if airDropPaused { resumeAirDrop() }
            return
        }
        guard airDropGuard == nil else { return }
        airDropGuard = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.anyScreenOn, self.cutAirDrop, AirDrop.helperInstalled else { return }
            let moving = Date().timeIntervalSince(self.lastActivity) < 2
            if !self.smartAirDrop || moving {
                if AirDrop.isActive { self.pauseAirDrop() }
            } else if self.airDropPaused {
                self.resumeAirDrop()
            }
        }
    }

    private func pauseAirDrop() {
        airDropPaused = true
        DispatchQueue.global(qos: .userInteractive).async { AirDrop.set(enabled: false) }
    }

    private func resumeAirDrop() {
        airDropPaused = false
        DispatchQueue.global(qos: .utility).async { AirDrop.set(enabled: true) }
    }

    func disconnect() {
        userStopped = true
        session?.stop()
    }

    private func updateIcon() {
        streaming = session?.streaming == true
        statusItem.button?.image = Brand.menuBarIcon(active: streaming || web.sessions.contains { $0.streaming })
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header: mascot, name, and a live status line with a colored dot.
        let status: String, color: NSColor
        let live = ([session].compactMap { $0 } + web.sessions).filter { $0.streaming }.map { $0.name }
        if !live.isEmpty { status = "Live on " + live.joined(separator: ", "); color = .systemGreen }
        else if let name = activeName { status = "Connecting to \(name)…"; color = .systemOrange }
        else if let err = lastError { status = err; color = .systemRed }
        else if receivers.isEmpty && web.sessions.isEmpty { status = "Looking for your other Mac…"; color = .systemGray }
        else { status = "Ready"; color = .systemGray }
        let header = NSMenuItem()
        header.view = MenuHeaderView(status: status, dot: color)
        menu.addItem(header)
        if localNetworkDenied || lastError == Messages.localNetwork {
            menu.addItem(item("Allow Local Network Access…", #selector(openLocalNetwork), symbol: "exclamationmark.triangle.fill"))
        }

        // The one-click action: unplug or plug back the extra screen.
        if session != nil || !web.sessions.isEmpty {
            let stop = item("Stop Extra Screen", #selector(toggleStreaming), key: "s", symbol: "stop.circle")
            stop.keyEquivalentModifierMask = [.control, .option, .command]
            menu.addItem(stop)
        } else if let name = lastReceiver ?? receivers.keys.sorted().first, receivers[name] != nil {
            let start = item("Start Extra Screen on \(name)", #selector(toggleStreaming), key: "s", symbol: "play.circle")
            start.keyEquivalentModifierMask = [.control, .option, .command]
            menu.addItem(start)
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Screens"))
        if receivers.isEmpty && web.sessions.isEmpty {
            let none = NSMenuItem(title: "Open Encore Screen on your other Mac", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for name in receivers.keys.sorted() {
            let screen = item(name, #selector(toggleReceiver(_:)), symbol: "display")
            screen.representedObject = name
            screen.state = activeName == name ? .on : .off
            menu.addItem(screen)
        }

        for w in web.sessions {
            let b = item(w.name, #selector(stopWebScreen(_:)), symbol: "globe")
            b.representedObject = w
            b.state = .on
            b.toolTip = "Click to disconnect"
            menu.addItem(b)
        }
        let add = NSMenuItem(title: "Add a Screen", action: nil, keyEquivalent: "")
        add.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        let addMenu = NSMenu()
        let qr = item("Phone, Tablet or Computer (Scan a QR Code)…", #selector(showQR), symbol: "qrcode")
        qr.toolTip = "Nothing to install: open the link in a browser on the device."
        addMenu.addItem(qr)
        let mac = item("Another Mac (Best Quality)…", #selector(showMacHelp), symbol: "desktopcomputer")
        mac.toolTip = "Install Encore Screen on the other Mac too. Smoothest option, ideal for an older iMac or MacBook."
        addMenu.addItem(mac)
        add.submenu = addMenu
        menu.addItem(add)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.addItem(.sectionHeader(title: "AirDrop while the extra screen is on"))
        for (title, mode) in [("Pause only while things move (recommended)", 0), ("Always pause", 1), ("Never pause", 2)] {
            let m = item(title, #selector(setAirDropMode(_:)))
            m.tag = mode
            m.state = airDropMode == mode ? .on : .off
            sub.addItem(m)
        }
        sub.addItem(.separator())
        let touch = item("Touch Control on Phones and Tablets", #selector(toggleTouch))
        touch.state = TouchInput.enabled ? .on : .off
        sub.addItem(touch)
        sub.addItem(item("Forget Allowed Screens", #selector(forgetDevices)))
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = LoginItem.enabled ? .on : .off
        sub.addItem(login)
        sub.addItem(.separator())
        sub.addItem(item("Setup Assistant…", #selector(openOnboarding)))
        settings.submenu = sub
        menu.addItem(settings)
        menu.addItem(item("Support Encore Screen ☕…", #selector(openSupport)))
        menu.addItem(item("Quit Encore Screen", #selector(quit), key: "q"))
    }

    @objc private func showMacHelp() {
        let alert = NSAlert()
        alert.messageText = "Use another Mac as your extra screen"
        alert.informativeText = "Install Encore Screen on the other Mac (macOS 10.15 or later), open it and choose \u{201C}Make this an extra screen\u{201D}. It shows up here automatically, on the same Wi-Fi.\n\nThis is the smoothest option, and it starts by itself with the other Mac."
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func forgetDevices() { ApprovedDevices.forgetAll() }
    @objc private func toggleTouch() { TouchInput.enabled.toggle() }

    @objc private func stopWebScreen(_ sender: NSMenuItem) { (sender.representedObject as? Session)?.stop() }

    @objc private func showQR() {
        let w = qrWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460), styleMask: [.titled, .closable],
                                    backing: .buffered, defer: false)
        w.title = "Encore Screen"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WebScreenQRView(server: web))
        qrWindow = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // 0 = pause only while moving, 1 = always pause, 2 = never pause.
    private var airDropMode: Int { !cutAirDrop ? 2 : smartAirDrop ? 0 : 1 }

    @objc private func setAirDropMode(_ sender: NSMenuItem) {
        if sender.tag != 2 && !AirDrop.helperInstalled { AirDrop.installHelper() }
        cutAirDrop = sender.tag != 2
        smartAirDrop = sender.tag == 0
        if sender.tag == 2 { airDropPaused = false; AirDrop.set(enabled: true) }
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func toggleReceiver(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if activeName == name { disconnect() } else { connect(name) }
    }

    @objc func toggleStreaming() {
        if session != nil || !web.sessions.isEmpty { disconnect(); web.stopAll(); return }
        if let name = lastReceiver ?? receivers.keys.sorted().first, receivers[name] != nil { connect(name) }
    }

    @objc private func toggleSmartAirDrop() { smartAirDrop.toggle() }

    @objc private func toggleAirDrop() {
        cutAirDrop.toggle()
        if cutAirDrop && !AirDrop.helperInstalled { AirDrop.installHelper() }
        if session != nil { AirDrop.set(enabled: !cutAirDrop) }
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.enabled) }

    @objc private func openOnboarding() { showOnboarding() }
    @objc private func openLocalNetwork() { LocalNetwork.openSettings() }
    @objc func switchRole() {
        session?.stop()
        if cutAirDrop { AirDrop.set(enabled: true) }
        onSwitchMode?()
    }

    @objc private func quit() {
        session?.stop()
        web.stopAll()
        if cutAirDrop { AirDrop.set(enabled: true) }
        NSApp.terminate(nil)
    }

    // MARK: Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Encore Screen"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(controller: self, close: { [weak w] in w?.close() }))
            onboardingWindow = w
        }
        onboardingWindow?.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func finishOnboarding() {
        defaults.set(true, forKey: "onboarded")
        onboardingWindow?.close()
        NSApp.setActivationPolicy(.accessory)
        autoConnect()
    }
}

// Top of the menu bar menu: the mascot, the app name and a status line with a colored dot.
final class MenuHeaderView: NSView {
    init(status: String, dot: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(x: 14, y: 8, width: 36, height: 36)
        addSubview(icon)
        let name = NSTextField(labelWithString: "Encore Screen")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.frame = NSRect(x: 58, y: 26, width: 210, height: 17)
        addSubview(name)
        let circle = NSView(frame: NSRect(x: 58, y: 13, width: 8, height: 8))
        circle.wantsLayer = true
        circle.layer?.backgroundColor = dot.cgColor
        circle.layer?.cornerRadius = 4
        addSubview(circle)
        let line = NSTextField(labelWithString: status)
        line.font = .systemFont(ofSize: 12)
        line.textColor = .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        line.frame = NSRect(x: 72, y: 8, width: 196, height: 16)
        addSubview(line)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@available(macOS 14.0, *)
struct OnboardingView: View {
    @ObservedObject var controller: Controller
    let close: () -> Void
    @State private var screenOK = ScreenPermission.granted
    @State private var askedScreen = false
    @State private var airDropOK = AirDrop.helperInstalled
    @State private var login = LoginItem.enabled
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Let Encore Screen show your extra screen",
                     askedScreen
                        ? "Turn on Encore Screen in the list that just opened. Not there? Drag Encore Screen from Finder into the list."
                        : "macOS asks for Screen Recording. Encore Screen only sends the extra screen to your other Mac.",
                     done: screenOK, button: askedScreen ? "Show in Finder" : "Allow") {
                    if askedScreen {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    } else {
                        ScreenPermission.request()
                        askedScreen = true
                    }
                }
                step(2, "Let it find your other Mac",
                     controller.localNetworkDenied
                        ? "macOS is blocking the connection. Turn on Encore Screen in Local Network settings."
                        : networkOK ? "Encore Screen can reach your other Mac on this network."
                        : controller.receivers.isEmpty ? "macOS may ask to find devices on your network. Click Allow."
                                                       : "Checking that macOS lets Encore Screen connect…",
                     done: networkOK, button: controller.localNetworkDenied ? "Open Settings" : nil,
                     searching: !networkOK && !controller.localNetworkDenied && !controller.receivers.isEmpty) { LocalNetwork.openSettings() }
                step(3, "Set up your extra screen",
                     receivers.isEmpty ? "On the other Mac, open Encore Screen and choose \u{201C}Make this an extra screen\u{201D}. Same Wi-Fi."
                                       : "Found \(receivers.joined(separator: ", ")). You're all set.",
                     done: !receivers.isEmpty, button: nil, searching: receivers.isEmpty && !controller.localNetworkDenied) {}
                step(4, "Make it smooth",
                     "Pauses AirDrop only while things move on the extra screen, so Wi-Fi stays steady. Asks for your password once.",
                     done: airDropOK, button: "Enable") { AirDrop.installHelper(); airDropOK = AirDrop.helperInstalled }
                Toggle("Open Encore Screen at login", isOn: $login)
                    .toggleStyle(.checkbox)
                    .onChange(of: login) { _, on in LoginItem.set(on) }
                    .padding(.top, 2)
                if controller.streaming, let name = controller.activeName {
                    HStack(spacing: 10) {
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your extra screen is on").font(.system(size: 14, weight: .semibold))
                            Text("\(name) is showing your extra screen. Drag a window to it, or stop anytime from the menu bar (⌃⌥⌘S).")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.1)))
                }
                Button {
                    if controller.lastReceiver == nil, let first = receivers.first { controller.lastReceiver = first }
                    controller.finishOnboarding()
                } label: {
                    Text(controller.streaming ? "Done" : receivers.isEmpty ? "Done" : "Start using \(receivers[0])")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.coralUI)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
                HStack(spacing: 6) {
                    Spacer()
                    Text("Is this the Mac you want as the extra screen?").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Switch to extra screen") { controller.switchRole() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                }
            }
            .padding(24)
        }
        .frame(width: 520)
        .onReceive(timer) { _ in screenOK = ScreenPermission.granted }
    }

    private var networkOK: Bool { controller.localNetworkOK }

    private var header: some View {
        ZStack {
            LinearGradient(colors: [Brand.orangeUI, Brand.coralUI], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                Text("Your main Mac").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Four quick steps and your other Mac becomes an extra screen.")
                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.92))
            }
            .padding(.top, 34).padding(.bottom, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var receivers: [String] { controller.receivers.keys.sorted() }

    @ViewBuilder
    private func step(_ n: Int, _ title: String, _ detail: String, done: Bool, button: String?,
                      searching: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Brand.coralUI.opacity(0.15)).frame(width: 32, height: 32)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Brand.coralUI)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if searching { ProgressView().controlSize(.small) }
            if let button, !done {
                Button(button, action: action).buttonStyle(.borderedProminent).tint(Brand.coralUI)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }
}
