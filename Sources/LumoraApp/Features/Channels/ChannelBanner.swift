import AppKit

/// TV-style banner shown for a few seconds after switching channel: logo, number, name,
/// category and country, LIVE, and a favourite star. Also shows "unavailable" with a countdown
/// and a Stay button when switching skips a dead channel.
@MainActor
final class ChannelBanner: NSView {
    var onStar: (() -> Void)?
    var onCancelSkip: (() -> Void)?

    private let panel = HUD.panel(cornerRadius: 14)
    private let logo = NSImageView()
    private let numberLabel = HUD.label(size: 13, weight: .semibold, color: HUD.secondaryText, monospaced: true)
    private let nameLabel = HUD.label(size: 17, weight: .semibold)
    private let detailLabel = HUD.label(size: 12, color: HUD.secondaryText)
    private let livePill = HUD.label(size: 10.5, weight: .bold, color: .white)
    private let star = NSButton()
    private let stayButton = NSButton(title: "Stay Here", target: nil, action: nil)
    private var hideWork: DispatchWorkItem?
    private var logoURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        alphaValue = 0
        isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 8
        logo.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        livePill.stringValue = " LIVE "
        livePill.wantsLayer = true
        livePill.layer?.backgroundColor = NSColor.systemRed.cgColor
        livePill.layer?.cornerRadius = 4
        star.isBordered = false
        star.target = self
        star.action = #selector(starClicked)
        stayButton.bezelStyle = .rounded
        stayButton.controlSize = .small
        stayButton.target = self
        stayButton.action = #selector(stayClicked)
        stayButton.isHidden = true

        let titleRow = NSStackView(views: [numberLabel, nameLabel, livePill])
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        let text = NSStackView(views: [titleRow, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [logo, text, stayButton, star])
        row.spacing = 14
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(row)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: panel.content.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: panel.content.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: panel.content.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: panel.content.bottomAnchor, constant: -12),
            logo.widthAnchor.constraint(equalToConstant: 72),
            logo.heightAnchor.constraint(equalToConstant: 48),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// Shows the channel for `duration` seconds (0 keeps it up).
    func show(_ channel: Channel, number: Int?, favourite: Bool, detail: String? = nil, duration: TimeInterval = 3.5) {
        numberLabel.stringValue = number.map(String.init) ?? ""
        numberLabel.isHidden = number == nil
        nameLabel.stringValue = channel.name
        detailLabel.stringValue = detail ?? [channel.group, channel.countryName].compactMap { $0 }.joined(separator: " · ")
        detailLabel.textColor = detail == nil ? HUD.secondaryText : .systemOrange
        livePill.isHidden = detail != nil
        stayButton.isHidden = true
        updateStar(favourite)
        loadLogo(channel.logo)
        setAccessibilityLabel("\(number.map { "Channel \($0), " } ?? "")\(channel.name), \(detailLabel.stringValue)")
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: accessibilityLabel() ?? channel.name])
        present(duration: duration)
    }

    /// "Unavailable — skipping in 3…" with a Stay button.
    func showSkipping(_ channel: Channel, number: Int?, seconds: Int) {
        show(channel, number: number, favourite: false, detail: "Unavailable right now · next channel in \(seconds)…", duration: 0)
        star.isHidden = true
        stayButton.isHidden = false
    }

    func updateStar(_ favourite: Bool) {
        star.isHidden = false
        star.image = NSImage(systemSymbolName: favourite ? "star.fill" : "star", accessibilityDescription: nil)
        star.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        star.contentTintColor = favourite ? .systemYellow : HUD.secondaryText
        star.toolTip = favourite ? "Remove from Favourites (⌘D)" : "Add to Favourites (⌘D)"
        star.setAccessibilityLabel(star.toolTip)
    }

    private func present(duration: TimeInterval) {
        hideWork?.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            animator().alphaValue = 1
        }
        guard duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }

    private func loadLogo(_ url: URL?) {
        logoURL = url
        logo.image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        logo.contentTintColor = HUD.secondaryText
        guard let url else { return }
        if let image = ChannelLogoLoader.shared.cached(url) {
            logo.image = image
            return
        }
        ChannelLogoLoader.shared.load(url) { [weak self] image in
            guard let self, self.logoURL == url, let image else { return }
            self.logo.image = image
        }
    }

    @objc private func starClicked() {
        onStar?()
    }

    @objc private func stayClicked() {
        onCancelSkip?()
    }
}
