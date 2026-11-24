import AppKit

/// Shown instead of a black screen for audio without cover art: a note symbol and the
/// title, artist and album from the file's tags.
@MainActor
final class AudioArtworkView: NSView {
    private let tile = NSView()
    private let icon = NSImageView()
    private let titleLabel = HUD.label(size: 20, weight: .semibold)
    private let detailLabel = HUD.label(size: 13, color: HUD.secondaryText)

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
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 22
        tile.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false
        icon.image = HUD.symbol("music.note", size: 64, weight: .light)
        icon.contentTintColor = HUD.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(icon)

        for label in [titleLabel, detailLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
        }
        let stack = NSStackView(views: [tile, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(22, after: tile)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 160),
            tile.heightAnchor.constraint(equalToConstant: 160),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    func update(title: String, tags: [String: String], isLive: Bool) {
        titleLabel.stringValue = tags["title"] ?? tags["icy-title"] ?? title
        let artist = tags["artist"] ?? tags["album_artist"] ?? tags["icy-name"]
        detailLabel.stringValue = [artist, tags["album"]].compactMap { $0 }.joined(separator: " — ")
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        icon.image = HUD.symbol(isLive ? "antenna.radiowaves.left.and.right" : "music.note", size: 64, weight: .light)
        setAccessibilityLabel([titleLabel.stringValue, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
