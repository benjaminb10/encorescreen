// Menu bar app: receiver discovery (Bonjour), connection, settings and onboarding.
import AppKit
import Network
import SwiftUI

final class Controller: NSObject, ObservableObject, NSMenuDelegate {
    @Published var receivers: [String: NWEndpoint] = [:]
    @Published var activeName: String?
    @Published var lastError: String?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var browser: NWBrowser?
    private var session: Session?
    private var userStopped = false
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
    var bitrate: Int { defaults.integer(forKey: "bitrate") > 0 ? defaults.integer(forKey: "bitrate") : 25_000_000 }

    func launch() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        statusItem.autosaveName = "SpareScreenStatusItem"
        Hotkey.register { [weak self] in self?.toggleStreaming() }
        startBrowsing()
        if !defaults.bool(forKey: "onboarded") { showOnboarding() }
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
                self.autoConnect()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func autoConnect() {
        guard session == nil, !userStopped, defaults.bool(forKey: "onboarded") || lastReceiver != nil,
              let name = lastReceiver, receivers[name] != nil else { return }
        connect(name)
    }

    // MARK: Connection

    func connect(_ name: String) {
        guard let endpoint = receivers[name] else { return }
        session?.stop()
        userStopped = false
        lastError = nil
        lastReceiver = name
        if cutAirDrop { AirDrop.set(enabled: false) }
        let s = Session(name: name, endpoint: endpoint, bitrate: bitrate)
        s.onStateChange = { [weak self] in self?.updateIcon() }
        s.onEnd = { [weak self, weak s] reason in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            self.activeName = nil
            if let reason { self.lastError = reason }
            if self.cutAirDrop { AirDrop.set(enabled: true) }
            self.updateIcon()
            // Unexpected drop (sleep, Wi-Fi): retry while the receiver is still advertised.
            if !self.userStopped && reason == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.autoConnect() }
            }
        }
        session = s
        activeName = name
        s.start()
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
        let title = NSMenuItem(title: "SpareScreen", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let status: String
        if let name = activeName { status = session?.streaming == true ? "Streaming to \(name)" : "Connecting to \(name)…" }
        else { status = "Not streaming" }
        menu.addItem(disabled(status))
        if let err = lastError { menu.addItem(disabled("⚠︎ " + err)) }

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
            menu.addItem(disabled("No receiver found on the network"))
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
        let air = NSMenuItem(title: "Pause AirDrop while streaming", action: #selector(toggleAirDrop), keyEquivalent: "")
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SpareScreen", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func toggleAirDrop() {
        cutAirDrop.toggle()
        if cutAirDrop && !AirDrop.helperInstalled { AirDrop.installHelper() }
        if session != nil { AirDrop.set(enabled: !cutAirDrop) }
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.enabled) }

    @objc private func openOnboarding() { showOnboarding() }

    @objc private func quit() {
        session?.stop()
        if cutAirDrop { AirDrop.set(enabled: true) }
        NSApp.terminate(nil)
    }

    // MARK: Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "SpareScreen"
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

struct OnboardingView: View {
    @ObservedObject var controller: Controller
    let close: () -> Void
    @State private var screenOK = ScreenPermission.granted
    @State private var airDropOK = AirDrop.helperInstalled
    @State private var login = LoginItem.enabled
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Allow screen recording",
                     "SpareScreen sends the picture of your extra screen to the other device.",
                     done: screenOK, button: "Allow") { ScreenPermission.request() }
                step(2, "Open SpareScreen Receiver on the other device",
                     receivers.isEmpty ? "Any Mac running macOS 10.15 or later, on the same Wi-Fi. Looking for it…"
                                       : "Found \(receivers.joined(separator: ", ")).",
                     done: !receivers.isEmpty, button: nil, searching: receivers.isEmpty) {}
                step(3, "Make it smooth",
                     "Pauses AirDrop while streaming, so Wi-Fi stays steady. Asks for your password once.",
                     done: airDropOK, button: "Enable") { AirDrop.installHelper(); airDropOK = AirDrop.helperInstalled }
                Toggle("Open SpareScreen at login", isOn: $login)
                    .toggleStyle(.checkbox)
                    .onChange(of: login) { _, on in LoginItem.set(on) }
                    .padding(.top, 4)
                Button {
                    if controller.lastReceiver == nil, let first = receivers.first { controller.lastReceiver = first }
                    controller.finishOnboarding()
                } label: {
                    Text(receivers.isEmpty ? "Done" : "Start streaming").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.coral)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            }
            .padding(24)
        }
        .frame(width: 520)
        .onReceive(timer) { _ in screenOK = ScreenPermission.granted }
    }

    private var header: some View {
        ZStack {
            LinearGradient(colors: [Brand.orange, Brand.coral], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                Text("SpareScreen").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Turn any device into an extra screen for your Mac.")
                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.92))
            }
            .padding(.top, 34).padding(.bottom, 22)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var receivers: [String] { controller.receivers.keys.sorted() }

    @ViewBuilder
    private func step(_ n: Int, _ title: String, _ detail: String, done: Bool, button: String?,
                      searching: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Brand.coral.opacity(0.15)).frame(width: 34, height: 34)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Brand.coral)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if searching { ProgressView().controlSize(.small) }
            if let button, !done {
                Button(button, action: action).buttonStyle(.borderedProminent).tint(Brand.coral)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }
}
