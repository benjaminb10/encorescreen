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
    private var probe: NWConnection?
    private var probeTimer: Timer?
    @Published var browsing = false
    var onSwitchMode: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var browser: NWBrowser?
    private var session: Session?
    private var userStopped = false
    private var airDropGuard: Timer?
    private var onboardingWindow: NSWindow?
    private let defaults = UserDefaults.standard

    var lastReceiver: String? {
        get { defaults.string(forKey: "lastReceiver") }
        set { defaults.set(newValue, forKey: "lastReceiver") }
    }
    // With the direct link, AirDrop's interface is the connection itself: never pause it.
    var cutAirDrop: Bool {
        get { !Transport.direct && (defaults.object(forKey: "cutAirDrop") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "cutAirDrop") }
    }
    var bitrate: Int { defaults.integer(forKey: "bitrate") > 0 ? defaults.integer(forKey: "bitrate") : 25_000_000 }

    func launch() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        statusItem.autosaveName = "EncoreScreenStatusItem"
        Hotkey.register { [weak self] in self?.toggleStreaming() }
        Transport.startMonitoring()
        startBrowsing()
        if !defaults.bool(forKey: "onboarded") { showOnboarding() }
        if !defaults.bool(forKey: "mainConfigured") {
            LoginItem.set(true)
            defaults.set(true, forKey: "mainConfigured")
        }
    }

    // MARK: Discovery

    private func startBrowsing() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true   // also find screens reachable over the direct link
        let b = NWBrowser(for: .bonjour(type: Proto.serviceType, domain: nil), using: params)
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
        let c = NWConnection(to: endpoint, using: Transport.apply(.udp))
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
        if cutAirDrop { AirDrop.set(enabled: false) }
        let s = Session(name: name, endpoint: endpoint, bitrate: bitrate)
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
            if let reason { self.lastError = reason }
            if reason == Messages.localNetwork { self.localNetworkDenied = true }
            if self.cutAirDrop { AirDrop.set(enabled: true) }
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
        // macOS turns AirDrop back on by itself from time to time: keep it paused for the whole session.
        airDropGuard?.invalidate()
        airDropGuard = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.session != nil, self.cutAirDrop, AirDrop.helperInstalled, AirDrop.isActive else { return }
            DispatchQueue.global().async { AirDrop.set(enabled: false) }
        }
        updateIcon()
    }

    func disconnect() {
        userStopped = true
        session?.stop()
    }

    private func updateIcon() {
        statusItem.button?.image = Brand.menuBarIcon(active: session?.streaming == true)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Encore Screen", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let status: String
        if let name = activeName { status = session?.streaming == true ? "Streaming to \(name)" : "Connecting to \(name)…" }
        else { status = "Not streaming" }
        menu.addItem(disabled(status))
        if let err = lastError { menu.addItem(disabled("⚠︎ " + err)) }
        if localNetworkDenied || lastError == Messages.localNetwork {
            let fix = NSMenuItem(title: "Open Local Network Settings…", action: #selector(openLocalNetwork), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        // The one-click action: unplug or plug back the extra screen.
        if session != nil {
            let stop = NSMenuItem(title: "Stop Streaming", action: #selector(toggleStreaming), keyEquivalent: "s")
            stop.keyEquivalentModifierMask = [.control, .option, .command]
            stop.target = self
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            menu.addItem(stop)
        } else if let name = lastReceiver ?? receivers.keys.sorted().first, receivers[name] != nil {
            let start = NSMenuItem(title: "Start Streaming to \(name)", action: #selector(toggleStreaming), keyEquivalent: "s")
            start.keyEquivalentModifierMask = [.control, .option, .command]
            start.target = self
            start.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
            menu.addItem(start)
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Available screens"))
        if receivers.isEmpty {
            menu.addItem(disabled("None yet: open Encore Screen on your other Mac"))
        }
        for name in receivers.keys.sorted() {
            let item = NSMenuItem(title: name, action: #selector(toggleReceiver(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = activeName == name ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let direct = NSMenuItem(title: "Direct Connection, Keeps AirDrop On (Beta)", action: #selector(toggleDirect), keyEquivalent: "")
        direct.target = self
        direct.state = Transport.direct ? .on : .off
        menu.addItem(direct)
        let air = NSMenuItem(title: "Pause AirDrop while streaming", action: #selector(toggleAirDrop), keyEquivalent: "")
        air.isEnabled = !Transport.direct
        air.target = self
        air.state = cutAirDrop ? .on : .off
        menu.addItem(air)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.enabled ? .on : .off
        menu.addItem(login)
        let setup = NSMenuItem(title: "Setup Assistant…", action: #selector(openOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let role = NSMenuItem(title: "Switch Role…", action: #selector(switchRole), keyEquivalent: "")
        role.target = self
        menu.addItem(role)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Encore Screen", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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
        if session != nil { disconnect(); return }
        if let name = lastReceiver ?? receivers.keys.sorted().first, receivers[name] != nil { connect(name) }
    }

    @objc private func toggleDirect() {
        Transport.direct.toggle()
        AirDrop.set(enabled: true)
        // Reconnect with the new transport.
        if let name = activeName { session?.stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.connect(name) } }
    }

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
                        : controller.receivers.isEmpty ? "macOS may ask to find devices on your network. Click Allow."
                                                       : "Checking that macOS lets Encore Screen connect…",
                     done: networkOK, button: controller.localNetworkDenied ? "Open Settings" : nil,
                     searching: !networkOK && !controller.localNetworkDenied && !controller.receivers.isEmpty) { LocalNetwork.openSettings() }
                step(3, "Set up your extra screen",
                     receivers.isEmpty ? "On the other Mac, open Encore Screen and choose \u{201C}Make this an extra screen\u{201D}. Same Wi-Fi."
                                       : "Found \(receivers.joined(separator: ", ")). You're all set.",
                     done: !receivers.isEmpty, button: nil, searching: receivers.isEmpty && !controller.localNetworkDenied) {}
                step(4, "Make it smooth",
                     "Pauses AirDrop while you use the extra screen, so Wi-Fi stays steady. Asks for your password once.",
                     done: airDropOK, button: "Enable") { AirDrop.installHelper(); airDropOK = AirDrop.helperInstalled }
                Toggle("Open Encore Screen at login", isOn: $login)
                    .toggleStyle(.checkbox)
                    .onChange(of: login) { _, on in LoginItem.set(on) }
                    .padding(.top, 2)
                Button {
                    if controller.lastReceiver == nil, let first = receivers.first { controller.lastReceiver = first }
                    controller.finishOnboarding()
                } label: {
                    Text(receivers.isEmpty ? "Done" : "Start using \(receivers[0])").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.coralUI)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
                HStack {
                    Spacer()
                    Button("Use this Mac differently…") { controller.switchRole() }
                        .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary)
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
