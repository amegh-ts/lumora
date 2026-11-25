import AppKit

enum ControlsAction {
    case togglePlayback
    case previous
    case next
    case skip(TimeInterval)
    case scrub(TimeInterval, finished: Bool)
    case hover(TimeInterval?, xInBar: CGFloat)
    case volume(Float)
    case toggleMute
    case toggleFullscreen
    case togglePlaylist
    case toggleChannels
}

enum ControlsMenu {
    case speed
    case audio
    case subtitles
    case more
}

@MainActor
final class ControlsOverlay: NSView {
    var onAction: ((ControlsAction) -> Void)?
    var menuProvider: ((ControlsMenu) -> NSMenu)?

    private let panel = HUD.panel(cornerRadius: 16, style: .glass)
    let timeline = TimelineView(frame: .zero)
    private let timeLabel = HUD.label(size: 11.5, weight: .medium, monospaced: true)
    private let remainingLabel = HUD.label(size: 11.5, weight: .medium, color: HUD.secondaryText, monospaced: true)
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private let playButton = HUDButton(symbol: "play.fill", size: 22, diameter: 42, tooltip: "Play")
    private let backButton = HUDButton(symbol: "gobackward.10", size: 16, diameter: 34, tooltip: "Back 10 seconds")
    private let forwardButton = HUDButton(symbol: "goforward.10", size: 16, diameter: 34, tooltip: "Forward 10 seconds")
    private let previousButton = HUDButton(symbol: "backward.end.fill", size: 13, diameter: 30, tooltip: "Previous item")
    private let nextButton = HUDButton(symbol: "forward.end.fill", size: 13, diameter: 30, tooltip: "Next item")
    private let volumeButton = HUDButton(symbol: "speaker.wave.2.fill", size: 13, tooltip: "Mute")
    private let speedButton = HUDTextButton(title: "1×", tooltip: "Playback speed")
    private let audioButton = HUDButton(symbol: "waveform", size: 14, tooltip: "Audio")
    private let subtitlesButton = HUDButton(symbol: "captions.bubble", size: 14, tooltip: "Subtitles")
    private let moreButton = HUDButton(symbol: "ellipsis.circle", size: 15, tooltip: "More")
    private let playlistButton = HUDButton(symbol: "sidebar.right", size: 14, tooltip: "Playlist")
    private let channelsButton = HUDButton(symbol: "tv", size: 14, tooltip: "Live TV (⇧⌘T)")
    private var channelMode = false
    private let fullscreenButton = HUDButton(symbol: "arrow.up.left.and.arrow.down.right", size: 13, tooltip: "Full screen")

    private var duration: TimeInterval = 0
    private var currentTime: TimeInterval = 0
    private static let showsRemainingKey = "lumora.controls.showsRemaining"
    private var showsRemaining = UserDefaults.standard.object(forKey: ControlsOverlay.showsRemainingKey) as? Bool ?? true
    private var hasNeighbours = false
    private var lastVolumeSymbol = ""
    private var isLive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))
        volumeSlider.setAccessibilityLabel("Volume")

        timeLabel.alignment = .left
        remainingLabel.alignment = .right
        let remainingClick = NSClickGestureRecognizer(target: self, action: #selector(toggleRemaining))
        remainingLabel.addGestureRecognizer(remainingClick)
        remainingLabel.toolTip = "Click to switch between remaining and total time"

        let leftGroup = NSStackView(views: [volumeButton, volumeSlider])
        leftGroup.spacing = 2
        let centerGroup = NSStackView(views: [previousButton, backButton, playButton, forwardButton, nextButton])
        centerGroup.spacing = 6
        let rightGroup = NSStackView(views: [speedButton, audioButton, subtitlesButton, moreButton, channelsButton, playlistButton, fullscreenButton])
        rightGroup.spacing = 2
        for group in [leftGroup, centerGroup, rightGroup] {
            group.orientation = .horizontal
            group.alignment = .centerY
            group.translatesAutoresizingMaskIntoConstraints = false
            panel.content.addSubview(group)
        }
        panel.content.addSubview(timeLabel)
        panel.content.addSubview(timeline)
        panel.content.addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 92),

            timeLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            timeLabel.centerYAnchor.constraint(equalTo: timeline.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 60),
            remainingLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            remainingLabel.centerYAnchor.constraint(equalTo: timeline.centerYAnchor),
            remainingLabel.widthAnchor.constraint(equalToConstant: 64),
            timeline.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 4),
            timeline.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -4),
            timeline.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            timeline.heightAnchor.constraint(equalToConstant: 20),

            centerGroup.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            centerGroup.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 6),
            leftGroup.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            leftGroup.centerYAnchor.constraint(equalTo: centerGroup.centerYAnchor),
            rightGroup.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            rightGroup.centerYAnchor.constraint(equalTo: centerGroup.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 84)
        ])

        playButton.onClick = { [weak self] in self?.onAction?(.togglePlayback) }
        backButton.onClick = { [weak self] in self?.onAction?(.skip(-10)) }
        forwardButton.onClick = { [weak self] in self?.onAction?(.skip(10)) }
        previousButton.onClick = { [weak self] in self?.onAction?(.previous) }
        nextButton.onClick = { [weak self] in self?.onAction?(.next) }
        volumeButton.onClick = { [weak self] in self?.onAction?(.toggleMute) }
        playlistButton.onClick = { [weak self] in self?.onAction?(.togglePlaylist) }
        channelsButton.onClick = { [weak self] in self?.onAction?(.toggleChannels) }
        fullscreenButton.onClick = { [weak self] in self?.onAction?(.toggleFullscreen) }
        speedButton.onClick = { [weak self] in self?.popMenu(.speed, from: self?.speedButton) }
        audioButton.onClick = { [weak self] in self?.popMenu(.audio, from: self?.audioButton) }
        subtitlesButton.onClick = { [weak self] in self?.popMenu(.subtitles, from: self?.subtitlesButton) }
        moreButton.onClick = { [weak self] in self?.popMenu(.more, from: self?.moreButton) }

        timeline.onScrub = { [weak self] time, finished in
            self?.onAction?(.scrub(time, finished: finished))
        }
        timeline.onHover = { [weak self] time, x in
            guard let self else { return }
            let point = self.convert(NSPoint(x: x, y: 0), from: self.timeline)
            self.onAction?(.hover(time, xInBar: point.x))
        }
        speedButton.setText("1×")
        update(time: 0, duration: 0)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        // Watching TV, channel up/down always shows; ±10 s matters less on live channels.
        previousButton.isHidden = channelMode ? false : (width < 600 || !hasNeighbours)
        nextButton.isHidden = channelMode ? false : (width < 600 || !hasNeighbours)
        backButton.isHidden = channelMode && width < 600
        forwardButton.isHidden = channelMode && width < 600
        channelsButton.isHidden = width < 480
        volumeSlider.isHidden = width < 520
        speedButton.isHidden = width < 460
        audioButton.isHidden = width < 430
        // Live TV has its own channel panel; the playlist of files doesn't apply.
        playlistButton.isHidden = width < 400 || channelMode
    }

    var isInteracting: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    /// Called up to 10×/s while playing; only touches views whose content actually changes.
    func update(time: TimeInterval, duration: TimeInterval) {
        currentTime = time
        self.duration = duration
        timeline.duration = duration
        timeline.currentTime = time
        setIfChanged(timeLabel, TimeFormatter.string(time))
        guard !isLive else { return }
        let remaining: String
        if duration <= 0 {
            remaining = "--:--"
        } else if showsRemaining {
            remaining = "-" + TimeFormatter.string(max(0, duration - time))
        } else {
            remaining = TimeFormatter.string(duration)
        }
        setIfChanged(remainingLabel, remaining)
    }

    private func setIfChanged(_ label: NSTextField, _ text: String) {
        if label.stringValue != text {
            label.stringValue = text
        }
    }

    func update(isPlaying: Bool) {
        playButton.setSymbol(isPlaying ? "pause.fill" : "play.fill", size: 22)
        playButton.toolTip = isPlaying ? "Pause" : "Play"
        playButton.setAccessibilityLabel(playButton.toolTip)
    }

    /// 1 normally, 2 with volume boost (the slider then goes to 200%).
    func setVolumeMax(_ value: Float) {
        volumeSlider.maxValue = Double(value)
    }

    func update(volume: Float, muted: Bool) {
        volumeSlider.floatValue = volume
        let symbol: String
        if muted || volume <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if volume < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        if symbol != lastVolumeSymbol {
            lastVolumeSymbol = symbol
            volumeButton.setSymbol(symbol, size: 13)
        }
        let label = muted ? "Unmute" : "Mute"
        volumeButton.toolTip = label
        volumeButton.setAccessibilityLabel(label)
        volumeSlider.setAccessibilityValueDescription("\(Int((volume * 100).rounded())) percent")
        volumeSlider.toolTip = volume > 1.0001 ? "Volume \(Int((volume * 100).rounded()))% (boosted)" : nil
    }

    func update(rate: Float) {
        let text = rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%g×", rate)
        speedButton.setText(text)
    }

    func update(hasPlaylistNeighbours: Bool, hasAudio: Bool, hasMedia: Bool, isFullscreen: Bool) {
        // With a single item Previous/Next are hidden rather than shown disabled.
        if hasNeighbours != hasPlaylistNeighbours {
            hasNeighbours = hasPlaylistNeighbours
            needsLayout = true
        }
        audioButton.isEnabled = hasAudio
        // Subtitles stay available without embedded tracks: the menu adds files or searches online.
        subtitlesButton.isEnabled = hasMedia
        fullscreenButton.setSymbol(
            isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            size: 13
        )
        fullscreenButton.toolTip = isFullscreen ? "Exit full screen" : "Full screen"
        fullscreenButton.setAccessibilityLabel(fullscreenButton.toolTip)
    }

    /// Live TV: Previous/Next become channel down/up, with the neighbouring channels as tooltips.
    func setChannelMode(_ on: Bool, previousName: String? = nil, nextName: String? = nil) {
        if on != channelMode {
            channelMode = on
            previousButton.setSymbol(on ? "chevron.down" : "backward.end.fill", size: on ? 15 : 13)
            nextButton.setSymbol(on ? "chevron.up" : "forward.end.fill", size: on ? 15 : 13)
            needsLayout = true
        }
        previousButton.toolTip = on ? "Channel down\(previousName.map { ": \($0)" } ?? "") (⌘↓)" : "Previous item"
        nextButton.toolTip = on ? "Channel up\(nextName.map { ": \($0)" } ?? "") (⌘↑)" : "Next item"
        previousButton.setAccessibilityLabel(previousButton.toolTip)
        nextButton.setAccessibilityLabel(nextButton.toolTip)
    }

    func setChannelsButtonActive(_ active: Bool) {
        channelsButton.contentTintColor = active ? HUD.accent : HUD.primaryText
    }

    func update(buffered: [ClosedRange<TimeInterval>]) {
        timeline.buffered = buffered
    }

    /// Live streams have no end: the seek bar goes away and a LIVE badge takes the time's place.
    func update(isLive live: Bool) {
        guard live != isLive else { return }
        isLive = live
        timeline.isHidden = live
        if live {
            remainingLabel.stringValue = "● LIVE"
            remainingLabel.textColor = .systemRed
            remainingLabel.toolTip = "Live stream"
            remainingLabel.setAccessibilityLabel("Live stream")
        } else {
            remainingLabel.textColor = HUD.secondaryText
            remainingLabel.toolTip = "Click to switch between remaining and total time"
            remainingLabel.setAccessibilityLabel(nil)
            update(time: currentTime, duration: duration)
        }
    }

    func update(loopA: TimeInterval?, loopB: TimeInterval?, chapters: [Chapter]) {
        timeline.loopA = loopA
        timeline.loopB = loopB
        timeline.chapters = chapters
    }

    private func popMenu(_ kind: ControlsMenu, from button: NSView?) {
        guard let button, let menu = menuProvider?(kind) else { return }
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        onAction?(.volume(sender.floatValue))
    }

    @objc private func toggleRemaining() {
        guard !isLive else { return }
        showsRemaining.toggle()
        UserDefaults.standard.set(showsRemaining, forKey: Self.showsRemainingKey)
        update(time: currentTime, duration: duration)
    }
}
