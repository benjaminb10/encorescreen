// First launch: "What is this Mac for?" Two big friendly choices. AppKit only, so it runs on Catalina.
import AppKit

final class ChoiceCard: NSView {
    var onClick: (() -> Void)?
    private let enabled: Bool
    private var hovering = false { didSet { refresh() } }

    init(emoji: String, title: String, detail: String, note: String?, enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 2
        let e = NSTextField(labelWithString: emoji)
        e.font = .systemFont(ofSize: 44)
        let t = label(title, size: 16, weight: .bold)
        let d = label(detail, size: 12, color: .secondaryLabelColor)
        var views: [NSView] = [e, t, d]
        if let note { views.append(label(note, size: 11, weight: .semibold, color: Brand.coral)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(equalToConstant: 260), heightAnchor.constraint(equalToConstant: 200),
        ])
        alphaValue = enabled ? 1 : 0.5
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        layer?.backgroundColor = (hovering && enabled ? Brand.coral.withAlphaComponent(0.08) : NSColor.textColor.withAlphaComponent(0.035)).cgColor
        layer?.borderColor = (hovering && enabled ? Brand.coral : NSColor.clear).cgColor
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; if enabled { NSCursor.pointingHand.set() } }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseUp(with event: NSEvent) { if enabled { onClick?() } }
}

final class ModeChooser: NSObject {
    let window: NSWindow
    var onChoose: ((AppMode) -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Encore Screen"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false

        let header = brandHeader(title: "Welcome to Encore Screen", tagline: "Give your old Mac an encore: it becomes your extra screen.")
        let question = label("How will you use this Mac?", size: 15, weight: .semibold)

        let main = ChoiceCard(emoji: "💻", title: "This is my main Mac",
                              detail: "The Mac you work on. It gets an extra screen, shown on your other Mac.",
                              note: AppMode.mainModeSupported ? nil : "Needs macOS 14 Sonoma or later.",
                              enabled: AppMode.mainModeSupported)
        let screen = ChoiceCard(emoji: "🖥️", title: "Make this an extra screen",
                                detail: "Lend this Mac's display to your main Mac. Perfect for an older iMac or MacBook.",
                                note: nil, enabled: true)
        main.onClick = { [weak self] in self?.onChoose?(.main) }
        screen.onClick = { [weak self] in self?.onChoose?(.screen) }
        let cards = NSStackView(views: [main, screen])
        cards.spacing = 16
        let footer = label("You'll need Encore Screen on both Macs. You can change this later from the menu.",
                           size: 11, color: .tertiaryLabelColor)

        let body = NSStackView(views: [question, cards, footer])
        body.orientation = .vertical
        body.alignment = .centerX
        body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        let root = NSStackView(views: [header, body])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .centerX
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.contentView = root
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
