import AppKit

/// Controls for the mini player: close and expand at the top, back/play/forward in the middle
/// and a thin seek bar at the bottom, over a light shade. Shown only while the pointer is over
/// the window, so the small video stays uncovered.
@MainActor
final class MiniControlsView: NSView {
    var onTogglePlayback: (() -> Void)?
    var onSkip: ((TimeInterval) -> Void)?
    var onScrub: ((TimeInterval, Bool) -> Void)?
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?

    private let shade = CAGradientLayer()
    private let playButton = HUDButton(symbol: "play.fill", size: 20, diameter: 42, tooltip: "Play")
    private let backButton = HUDButton(symbol: "gobackward.10", size: 14, diameter: 32, tooltip: "Back 10 seconds")
    private let forwardButton = HUDButton(symbol: "goforward.10", size: 14, diameter: 32, tooltip: "Forward 10 seconds")
    private let expandButton = HUDButton(symbol: "arrow.up.left.and.arrow.down.right", size: 11, diameter: 26, tooltip: "Back to the full window")
    private let closeButton = HUDButton(symbol: "xmark", size: 11, diameter: 26, tooltip: "Close")
    private let timeline = TimelineView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        shade.colors = [
            NSColor.black.withAlphaComponent(0.45).cgColor, NSColor.black.withAlphaComponent(0.15).cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor
        ]
        shade.locations = [0, 0.5, 1]
        layer?.addSublayer(shade)

        let center = NSStackView(views: [backButton, playButton, forwardButton])
        center.spacing = 10
        for view in [center, expandButton, closeButton, timeline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expandButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            timeline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            timeline.heightAnchor.constraint(equalToConstant: 16)
        ])
        playButton.onClick = { [weak self] in self?.onTogglePlayback?() }
        backButton.onClick = { [weak self] in self?.onSkip?(-10) }
        forwardButton.onClick = { [weak self] in self?.onSkip?(10) }
        expandButton.onClick = { [weak self] in self?.onExpand?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        timeline.onScrub = { [weak self] time, finished in self?.onScrub?(time, finished) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        CATransaction.commit()
        // Very small windows keep only play/pause.
        backButton.isHidden = bounds.width < 260
        forwardButton.isHidden = bounds.width < 260
    }

    func update(time: TimeInterval, duration: TimeInterval) {
        timeline.duration = duration
        timeline.currentTime = time
        timeline.isHidden = duration <= 0
    }

    func update(isPlaying: Bool) {
        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill", size: 20)
        playButton.toolTip = isPlaying ? "Pause" : "Play"
        playButton.setAccessibilityLabel(playButton.toolTip)
    }
}
