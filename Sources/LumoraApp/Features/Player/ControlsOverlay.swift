import AppKit

struct SubtitleChoice: Hashable {
    var title: String
    var id: String?
}

enum ControlsAction {
    case togglePlayback
    case previous
    case next
    case seekBackward
    case seekForward
    case seek(Double)
    case hover(Double?)
    case volume(Float)
    case toggleMute
    case toggleFullscreen
    case togglePictureInPicture
    case togglePlaylist
    case screenshot
    case audioTrack(Int32?)
    case subtitleOption(String?)
    case toggleAirPlay
}

@MainActor
final class ControlsOverlay: NSVisualEffectView, SeekSliderDelegate {
    var onAction: ((ControlsAction) -> Void)?

    private enum Tag: Int {
        case playPause = 1
        case previous
        case backward
        case forward
        case next
        case mute
        case screenshot
        case pictureInPicture
        case playlist
        case fullscreen
    }

    private let seekSlider = SeekSlider(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
    private let volumeSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 90, height: 20))
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let audioPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
    private let subtitlePopUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
    private let thumbnailPreview = ThumbnailPreviewView(frame: NSRect(x: 0, y: 0, width: 200, height: 112))

    private let playPauseButton = ControlsOverlay.makeButton(symbol: "play.fill", tag: .playPause, accessibility: "Play")
    private let previousButton = ControlsOverlay.makeButton(symbol: "backward.end.fill", tag: .previous, accessibility: "Previous")
    private let backwardButton = ControlsOverlay.makeButton(symbol: "gobackward.10", tag: .backward, accessibility: "Back 10 seconds")
    private let forwardButton = ControlsOverlay.makeButton(symbol: "goforward.10", tag: .forward, accessibility: "Forward 10 seconds")
    private let nextButton = ControlsOverlay.makeButton(symbol: "forward.end.fill", tag: .next, accessibility: "Next")
    private let muteButton = ControlsOverlay.makeButton(symbol: "speaker.wave.2.fill", tag: .mute, accessibility: "Mute")
    private let screenshotButton = ControlsOverlay.makeButton(symbol: "camera", tag: .screenshot, accessibility: "Screenshot")
    private let pictureInPictureButton = ControlsOverlay.makeButton(symbol: "pip", tag: .pictureInPicture, accessibility: "Picture in Picture")
    private let playlistButton = ControlsOverlay.makeButton(symbol: "list.bullet", tag: .playlist, accessibility: "Playlist")
    private let fullscreenButton = ControlsOverlay.makeButton(symbol: "arrowspace.right", tag: .fullscreen, accessibility: "Fullscreen")

    private var audioIDs: [Int32?] = [nil]
    private var subtitleChoices: [SubtitleChoice] = [SubtitleChoice(title: "Off", id: nil)]
    private var isUpdatingTracks = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        material = .hudWindow
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        seekSlider.hoverDelegate = self
        volumeSlider.isContinuous = true
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.target = self
        volumeSlider.action = #selector(sliderChanged(_:))

        for button in [playPauseButton, previousButton, backwardButton, forwardButton, nextButton,
                       muteButton, screenshotButton, pictureInPictureButton, playlistButton, fullscreenButton] {
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(buttonTapped(_:))
        }

        audioPopUp.target = self
        audioPopUp.action = #selector(popupChanged(_:))
        subtitlePopUp.target = self
        subtitlePopUp.action = #selector(popupChanged(_:))
        audioPopUp.addItem(withTitle: "Default")
        subtitlePopUp.addItem(withTitle: "Off")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = .labelColor
        durationLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        durationLabel.alignment = .left

        let routeButton = CastService.shared.routeButton(target: self, action: #selector(airplayTapped(_:)))
        let timeline = NSStackView(views: [timeLabel, seekSlider, durationLabel])
        timeline.orientation = .horizontal
        timeline.spacing = 8

        let buttonRow = NSStackView(views: [
            previousButton, backwardButton, playPauseButton, forwardButton, nextButton,
            muteButton, volumeSlider, audioPopUp, subtitlePopUp,
            routeButton, screenshotButton, pictureInPictureButton, playlistButton, fullscreenButton
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6

        let stack = NSStackView(views: [timeline, buttonRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(thumbnailPreview)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            timeLabel.widthAnchor.constraint(equalToConstant: 52),
            durationLabel.widthAnchor.constraint(equalToConstant: 52),
            volumeSlider.widthAnchor.constraint(equalToConstant: 84),
            audioPopUp.widthAnchor.constraint(equalToConstant: 116),
            subtitlePopUp.widthAnchor.constraint(equalToConstant: 116),
            routeButton.widthAnchor.constraint(equalToConstant: 64),
            thumbnailPreview.widthAnchor.constraint(equalToConstant: 200),
            thumbnailPreview.heightAnchor.constraint(equalToConstant: 112),
            thumbnailPreview.centerXAnchor.constraint(equalTo: seekSlider.centerXAnchor),
            thumbnailPreview.bottomAnchor.constraint(equalTo: seekSlider.topAnchor, constant: -8)
        ])
    }

    func update(time: TimeInterval, duration: TimeInterval, isPlaying: Bool, volume: Float) {
        seekSlider.maxValue = max(duration, 1)
        seekSlider.doubleValue = time
        timeLabel.stringValue = TimeFormatter.string(time)
        durationLabel.stringValue = TimeFormatter.string(duration)
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: isPlaying ? "Pause" : "Play"
        )
        volumeSlider.floatValue = volume
        muteButton.image = NSImage(
            systemSymbolName: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: "Mute"
        )
    }

    func updateTrackMenus(
        audio: [MediaTrack],
        selectedAudio: Int32?,
        subtitles: [SubtitleChoice],
        selectedSubtitle: String?
    ) {
        isUpdatingTracks = true
        defer { isUpdatingTracks = false }

        audioIDs = [nil] + audio.map { Optional($0.id) }
        audioPopUp.removeAllItems()
        audioPopUp.addItem(withTitle: "Default")
        for track in audio {
            audioPopUp.addItem(withTitle: "\(track.title) (\(track.language))")
        }
        let audioIndex = audio.firstIndex { $0.id == selectedAudio }.map { $0 + 1 } ?? 0
        audioPopUp.selectItem(at: audioIndex)

        subtitleChoices = subtitles.isEmpty ? [SubtitleChoice(title: "Off", id: nil)] : subtitles
        subtitlePopUp.removeAllItems()
        for choice in subtitleChoices {
            subtitlePopUp.addItem(withTitle: choice.title)
        }
        let subtitleIndex = subtitleChoices.firstIndex { $0.id == selectedSubtitle } ?? 0
        subtitlePopUp.selectItem(at: subtitleIndex)
    }

    func showThumbnail(image: NSImage?, time: TimeInterval) {
        thumbnailPreview.show(image: image, time: time)
    }

    func hideThumbnail() {
        thumbnailPreview.hide()
    }

    func seekSliderDidChange(_ slider: SeekSlider) {
        let fraction = seekFraction()
        onAction?(.seek(fraction))
    }

    func seekSlider(_ slider: SeekSlider, didHoverAt fraction: Double?) {
        guard let fraction else {
            hideThumbnail()
            onAction?(.hover(nil))
            return
        }
        onAction?(.hover(fraction))
    }

    private static func makeButton(symbol: String, tag: Tag, accessibility: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility) ?? NSImage(),
            target: nil,
            action: nil
        )
        button.tag = tag.rawValue
        button.toolTip = accessibility
        return button
    }

    private func seekFraction() -> Double {
        let maximum = max(seekSlider.maxValue, 1)
        return min(max(seekSlider.doubleValue / maximum, 0), 1)
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let tag = Tag(rawValue: sender.tag) else { return }
        switch tag {
        case .playPause: onAction?(.togglePlayback)
        case .previous: onAction?(.previous)
        case .backward: onAction?(.seekBackward)
        case .forward: onAction?(.seekForward)
        case .next: onAction?(.next)
        case .mute: onAction?(.toggleMute)
        case .screenshot: onAction?(.screenshot)
        case .pictureInPicture: onAction?(.togglePictureInPicture)
        case .playlist: onAction?(.togglePlaylist)
        case .fullscreen: onAction?(.toggleFullscreen)
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        if sender == volumeSlider {
            onAction?(.volume(sender.floatValue))
        }
    }

    @objc private func airplayTapped(_ sender: Any) {
        onAction?(.toggleAirPlay)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingTracks else { return }
        if sender == audioPopUp {
            let index = sender.indexOfSelectedItem
            let id: Int32? = audioIDs.indices.contains(index) ? audioIDs[index] : nil
            onAction?(.audioTrack(id))
        } else if sender == subtitlePopUp {
            let index = sender.indexOfSelectedItem
            let id: String? = subtitleChoices.indices.contains(index) ? subtitleChoices[index].id : nil
            onAction?(.subtitleOption(id))
        }
    }
}
