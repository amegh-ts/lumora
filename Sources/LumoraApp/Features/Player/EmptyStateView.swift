import AppKit

@MainActor
final class EmptyStateView: NSView {
    var onOpenFile: (() -> Void)?
    var onOpenURL: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = HUD.label(size: 22, weight: .semibold)
    private let subtitleLabel = HUD.label(size: 13, color: HUD.secondaryText)
    private let errorLabel = HUD.label(size: 12.5, weight: .medium, color: NSColor.systemRed.blended(withFraction: 0.35, of: .white) ?? .systemRed)
    private let recentStack = NSStackView()
    private let recentHeader = HUD.label(size: 11, weight: .semibold, color: HUD.secondaryText)
    private var isDropTarget = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)

        iconView.image = HUD.symbol("play.rectangle.on.rectangle", size: 44, weight: .light)
        iconView.contentTintColor = HUD.secondaryText
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = "Drop a video here"
        titleLabel.alignment = .center
        subtitleLabel.stringValue = "Lumora plays almost any video or audio file, folder or stream."
        subtitleLabel.alignment = .center
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.isHidden = true

        let openButton = NSButton(title: "Open File…", target: self, action: #selector(openFile))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"
        let urlButton = NSButton(title: "Open URL…", target: self, action: #selector(openURL))
        urlButton.bezelStyle = .rounded
        urlButton.controlSize = .large
        let buttons = NSStackView(views: [openButton, urlButton])
        buttons.spacing = 10

        recentHeader.stringValue = "CONTINUE WATCHING"
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, errorLabel, buttons, recentHeader, recentStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(20, after: errorLabel)
        stack.setCustomSpacing(30, after: buttons)
        stack.setCustomSpacing(6, after: recentHeader)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Margins give way when the window is smaller than the text (e.g. the mini player,
        // where this view is hidden) instead of setting the window's minimum width.
        let leading = stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24)
        let trailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        leading.priority = NSLayoutConstraint.Priority(450)
        trailing.priority = NSLayoutConstraint.Priority(450)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            leading,
            trailing,
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
    }

    func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    func setDropTarget(_ active: Bool) {
        isDropTarget = active
    }

    func setRecent(_ records: [LibraryRecord]) {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = records.prefix(4)
        recentHeader.isHidden = items.isEmpty
        recentStack.isHidden = items.isEmpty
        for record in items {
            let progress = record.duration > 0 ? Int((record.resumeTime / record.duration * 100).rounded()) : 0
            let button = RecentRowButton(
                title: record.title,
                detail: "\(TimeFormatter.string(record.resumeTime)) of \(TimeFormatter.string(record.duration)) · \(progress)%"
            )
            let url = record.url
            button.onClick = { [weak self] in self?.onOpenRecent?(url) }
            recentStack.addArrangedSubview(button)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isDropTarget else { return }
        let rect = bounds.insetBy(dx: 18, dy: 18)
        let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        HUD.accent.withAlphaComponent(0.9).setStroke()
        path.stroke()
        HUD.accent.withAlphaComponent(0.08).setFill()
        path.fill()
    }

    @objc private func openFile() {
        onOpenFile?()
    }

    @objc private func openURL() {
        onOpenURL?()
    }
}

@MainActor
private final class RecentRowButton: NSView {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(title: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        let icon = NSImageView(image: HUD.symbol("play.circle", size: 15) ?? NSImage())
        icon.contentTintColor = HUD.secondaryText
        let titleLabel = HUD.label(size: 13, weight: .medium)
        titleLabel.stringValue = title
        let detailLabel = HUD.label(size: 11.5, color: HUD.secondaryText, monospaced: true)
        detailLabel.stringValue = detail
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(equalToConstant: 420)
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Resume \(title)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {}

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}
