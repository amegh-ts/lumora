import AppKit

private enum SettingsControlTag: Int {
    case remember = 1
    case autoplayNext
    case shuffle
    case repeatMode
    case videoGravity
    case volume
    case brightness
    case contrast
    case saturation
    case hardwareDecoding
    case renderer
    case checkForUpdates
    case subtitleSize
    case subtitleDelay
    case autoDownloadSubtitles
    case subtitleLanguages
    case openSubtitlesAPIKey
    case ytDLPPath
    case ffmpegPath
}

private let equalizerTagBase = 1000

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let settings = SettingsStore.shared

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumora Settings"
        window.center()
        self.init(window: window)

        let viewController = NSViewController(nibName: nil, bundle: nil)
        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        tabView.addTabViewItem(tabItem(title: "General", view: generalPane()))
        tabView.addTabViewItem(tabItem(title: "Playback", view: playbackPane()))
        tabView.addTabViewItem(tabItem(title: "Subtitles", view: subtitlesPane()))
        tabView.addTabViewItem(tabItem(title: "Tools", view: toolsPane()))
        tabView.translatesAutoresizingMaskIntoConstraints = false
        viewController.view = tabView
        window.contentViewController = viewController
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor)
        ])
    }

    private func tabItem(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func generalPane() -> NSView {
        let repeatPopup = popup(
            tag: .repeatMode,
            titles: RepeatMode.allCases.map { $0.rawValue.capitalized },
            selected: settings.repeatMode.rawValue.capitalized
        )
        let gravityPopup = popup(
            tag: .videoGravity,
            titles: VideoGravityPreference.allCases.map { $0.rawValue.capitalized },
            selected: settings.videoGravity.rawValue.capitalized
        )
        return pane(rows: [
            section("Library"),
            checkbox(title: "Remember playback position", tag: .remember, value: settings.rememberLastPosition),
            checkbox(title: "Autoplay next item", tag: .autoplayNext, value: settings.autoplayNext),
            checkbox(title: "Shuffle", tag: .shuffle, value: settings.shuffle),
            row(label: "Repeat", control: repeatPopup),
            row(label: "Video scaling", control: gravityPopup),
            section("Updates"),
            checkbox(title: "Check for updates automatically", tag: .checkForUpdates, value: settings.checkForUpdates)
        ])
    }

    private func playbackPane() -> NSView {
        var rows: [NSView] = [
            section("Basics"),
            row(label: "Volume", control: slider(tag: .volume, min: 0, max: 1, value: Double(settings.volume))),
            checkbox(title: "Hardware decoding", tag: .hardwareDecoding, value: settings.hardwareDecoding),
            row(label: "Renderer", control: popup(
                tag: .renderer,
                titles: VideoRenderer.allCases.map(\.title),
                selected: settings.renderer.title
            )),
            label("Renderer changes apply to new player windows."),
            section("Video adjustments"),
            row(label: "Brightness", control: slider(tag: .brightness, min: -1, max: 1, value: settings.brightness)),
            row(label: "Contrast", control: slider(tag: .contrast, min: 0, max: 2, value: settings.contrast)),
            row(label: "Saturation", control: slider(tag: .saturation, min: 0, max: 2, value: settings.saturation)),
            section("Equalizer")
        ]
        let frequencies = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        for (index, frequency) in frequencies.enumerated() {
            rows.append(row(
                label: frequency,
                control: slider(rawTag: equalizerTagBase + index, min: -12, max: 12, value: settings.equalizerGains[index])
            ))
        }
        return pane(rows: rows)
    }

    private func subtitlesPane() -> NSView {
        pane(rows: [
            section("Display"),
            row(label: "Font size", control: slider(tag: .subtitleSize, min: 14, max: 48, value: settings.subtitleSize)),
            row(label: "Delay", control: slider(tag: .subtitleDelay, min: -10, max: 10, value: settings.subtitleDelay)),
            section("OpenSubtitles"),
            checkbox(title: "Download automatically", tag: .autoDownloadSubtitles, value: settings.autoDownloadSubtitles),
            row(label: "Languages", control: textField(tag: .subtitleLanguages, value: settings.subtitleLanguages, secure: false)),
            row(label: "API key", control: textField(tag: .openSubtitlesAPIKey, value: settings.openSubtitlesAPIKey, secure: true))
        ])
    }

    private func toolsPane() -> NSView {
        pane(rows: [
            section("External tools"),
            row(label: "yt-dlp path", control: textField(tag: .ytDLPPath, value: settings.ytDLPPath, secure: false)),
            row(label: "ffmpeg path", control: textField(tag: .ffmpegPath, value: settings.ffmpegPath, secure: false)),
            section("Privacy"),
            label("Crash logs are stored locally under Application Support/Lumora/Logs.")
        ])
    }

    private func pane(rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        return scrollView
    }

    private func section(_ title: String) -> NSView {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        return field
    }

    private func label(_ title: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: title)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func row(label title: String, control: NSView) -> NSView {
        let field = NSTextField(labelWithString: title)
        field.alignment = .right
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [field, control])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func checkbox(title: String, tag: SettingsControlTag, value: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(controlChanged(_:)))
        button.setButtonType(.switch)
        button.state = value ? .on : .off
        button.tag = tag.rawValue
        return button
    }

    private func slider(tag: SettingsControlTag, min: Double, max: Double, value: Double) -> NSSlider {
        slider(rawTag: tag.rawValue, min: min, max: max, value: value)
    }

    private func slider(rawTag: Int, min: Double, max: Double, value: Double) -> NSSlider {
        let control = NSSlider(frame: NSRect(x: 0, y: 0, width: 340, height: 20))
        control.minValue = min
        control.maxValue = max
        control.doubleValue = value
        control.isContinuous = true
        control.target = self
        control.action = #selector(controlChanged(_:))
        control.tag = rawTag
        return control
    }

    private func textField(tag: SettingsControlTag, value: String, secure: Bool) -> NSTextField {
        let field: NSTextField
        if secure {
            field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        } else {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        }
        field.stringValue = value
        field.target = self
        field.action = #selector(controlChanged(_:))
        field.tag = tag.rawValue
        return field
    }

    private func popup(tag: SettingsControlTag, titles: [String], selected: String) -> NSPopUpButton {
        let control = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 24), pullsDown: false)
        control.addItems(withTitles: titles)
        control.selectItem(withTitle: selected)
        control.target = self
        control.action = #selector(controlChanged(_:))
        control.tag = tag.rawValue
        return control
    }

    @objc private func controlChanged(_ sender: NSControl) {
        if (equalizerTagBase..<equalizerTagBase + 10).contains(sender.tag) {
            settings.equalizerGains[sender.tag - equalizerTagBase] = sender.doubleValue
            return
        }
        guard let tag = SettingsControlTag(rawValue: sender.tag) else { return }
        switch tag {
        case .remember: settings.rememberLastPosition = sender.integerValue == 1
        case .autoplayNext: settings.autoplayNext = sender.integerValue == 1
        case .shuffle: settings.shuffle = sender.integerValue == 1
        case .repeatMode:
            let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            settings.repeatMode = RepeatMode.allCases[index]
        case .videoGravity:
            let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            settings.videoGravity = VideoGravityPreference.allCases[index]
        case .volume: settings.volume = sender.floatValue
        case .brightness: settings.brightness = sender.doubleValue
        case .contrast: settings.contrast = sender.doubleValue
        case .saturation: settings.saturation = sender.doubleValue
        case .hardwareDecoding: settings.hardwareDecoding = sender.integerValue == 1
        case .renderer:
            let index = (sender as? NSPopUpButton)?.indexOfSelectedItem ?? 0
            settings.renderer = VideoRenderer.allCases[index]
        case .checkForUpdates: settings.checkForUpdates = sender.integerValue == 1
        case .subtitleSize: settings.subtitleSize = sender.doubleValue
        case .subtitleDelay: settings.subtitleDelay = sender.doubleValue
        case .autoDownloadSubtitles: settings.autoDownloadSubtitles = sender.integerValue == 1
        case .subtitleLanguages: settings.subtitleLanguages = sender.stringValue
        case .openSubtitlesAPIKey: settings.openSubtitlesAPIKey = sender.stringValue
        case .ytDLPPath: settings.ytDLPPath = sender.stringValue
        case .ffmpegPath: settings.ffmpegPath = sender.stringValue
        }
    }
}
