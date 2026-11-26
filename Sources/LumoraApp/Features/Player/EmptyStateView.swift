import AppKit

@MainActor
final class EmptyStateView: NSView {
    var onOpenFile: (() -> Void)?
    var onOpenURL: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onLiveTV: (() -> Void)?
    var onContinueChannel: (() -> Void)?
    private let continueChannelButton = NSButton(title: "", target: nil, action: nil)

    private let iconView = NSImageView()
    private let titleLabel = HUD.label(size: 22, weight: .semibold)
    private let subtitleLabel = HUD.label(size: 13, color: HUD.secondaryText)
    private let errorLabel = HUD.label(size: 12.5, weight: .medium, color: NSColor.systemRed.blended(withFraction: 0.35, of: .white) ?? .systemRed)
    private let recentStack = NSStackView()
    private let recentHeader = HUD.label(size: 11, weight: .semibold, color: HUD.secondaryText)
    private let errorCard = NSView()
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
        errorLabel.maximumNumberOfLines = 4
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.preferredMaxLayoutWidth = 440
        errorLabel.isHidden = true
        // Errors sit in a soft red card instead of loose red text.
        errorCard.wantsLayer = true
        errorCard.layer?.cornerRadius = 12
        errorCard.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        errorCard.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
        errorCard.layer?.borderWidth = 1
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorCard.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: errorCard.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: errorCard.trailingAnchor, constant: -16),
            errorLabel.topAnchor.constraint(equalTo: errorCard.topAnchor, constant: 10),
            errorLabel.bottomAnchor.constraint(equalTo: errorCard.bottomAnchor, constant: -10)
        ])
        errorCard.isHidden = true

        let openButton = NSButton(title: "Open File…", target: self, action: #selector(openFile))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"
        let urlButton = NSButton(title: "Open URL…", target: self, action: #selector(openURL))
        urlButton.bezelStyle = .rounded
        urlButton.controlSize = .large
        let tvButton = NSButton(title: "Live TV", target: self, action: #selector(liveTV))
        tvButton.bezelStyle = .rounded
        tvButton.controlSize = .large
        tvButton.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        tvButton.imagePosition = .imageLeading
        continueChannelButton.bezelStyle = .inline
        continueChannelButton.target = self
        continueChannelButton.action = #selector(continueChannel)
        continueChannelButton.isHidden = true
        let buttons = NSStackView(views: [openButton, urlButton, tvButton])
        buttons.spacing = 10

        recentHeader.stringValue = "CONTINUE WATCHING"
        recentStack.orientation = .horizontal
        recentStack.alignment = .top
        recentStack.spacing = 12

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, errorCard, buttons, continueChannelButton, recentHeader, recentStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: iconView)
        stack.setCustomSpacing(20, after: errorCard)
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
            errorCard.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
    }

    func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
        errorCard.isHidden = message == nil
    }

    /// "Continue watching <channel>" under the buttons, when a channel was watched before.
    func setLastChannel(_ name: String?) {
        continueChannelButton.isHidden = name == nil
        continueChannelButton.title = name.map { "▶︎ Continue watching \($0)" } ?? ""
    }

    @objc private func liveTV() {
        onLiveTV?()
    }

    @objc private func continueChannel() {
        onContinueChannel?()
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
            let card = RecentCard(record: record)
            let url = record.url
            card.onClick = { [weak self] in self?.onOpenRecent?(url) }
            recentStack.addArrangedSubview(card)
        }
        loadThumbnails(recentStack.arrangedSubviews.compactMap { $0 as? RecentCard })
    }

    private func loadThumbnails(_ cards: [RecentCard]) {
        guard let first = cards.first else { return }
        first.loadThumbnail { [weak self] in self?.loadThumbnails(Array(cards.dropFirst())) }
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

/// A Continue Watching card: a frame from the video, its title, time left and progress.
@MainActor
private final class RecentCard: NSView {
    var onClick: (() -> Void)?
    private let thumbnail = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 0.12 : 0.06).cgColor }
    }

    init(record: LibraryRecord) {
        self.record = record
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        thumbnail.imageScaling = .scaleNone
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 6
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        thumbnail.image = NSImage(systemSymbolName: record.url.isFileURL ? "film" : "globe", accessibilityDescription: nil)
        thumbnail.symbolConfiguration = .init(pointSize: 22, weight: .light)
        thumbnail.contentTintColor = HUD.secondaryText

        let title = HUD.label(size: 12, weight: .semibold)
        title.stringValue = record.title
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let left = max(0, record.duration - record.resumeTime)
        let detail = HUD.label(size: 10.5, color: HUD.secondaryText, monospaced: true)
        detail.stringValue = "\(TimeFormatter.string(left)) left"
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.controlSize = .mini
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = record.duration > 0 ? min(max(record.resumeTime / record.duration, 0), 1) : 0

        let stack = NSStackView(views: [thumbnail, title, detail, progress])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(8, after: thumbnail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 170),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            thumbnail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9.0 / 16.0),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Resume \(record.title), \(TimeFormatter.string(left)) left")

    }

    let record: LibraryRecord

    /// A frame from where you stopped (local files only; streams keep the icon). The thumbnail
    /// service handles one request at a time, so cards load one after another.
    func loadThumbnail(then next: @escaping () -> Void) {
        guard record.url.isFileURL, record.duration > 0 else {
            next()
            return
        }
        ThumbnailService.shared.request(url: record.url, time: record.resumeTime, duration: record.duration) { [weak self] image in
            if let self, let image {
                self.thumbnail.imageScaling = .scaleProportionallyUpOrDown
                self.thumbnail.symbolConfiguration = nil
                self.thumbnail.image = image
            }
            next()
        }
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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
