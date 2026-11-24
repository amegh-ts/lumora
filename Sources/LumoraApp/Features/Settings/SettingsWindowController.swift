import AppKit

/// Preferences window: a native toolbar with one pane per topic, each built from grouped sections.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabs = NSTabViewController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        self.init(window: window)

        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        let panes: [(String, String, () -> [NSView])] = [
            ("General", "gearshape", SettingsPanes.general),
            ("Video", "tv", SettingsPanes.video),
            ("Audio", "speaker.wave.2", SettingsPanes.audio),
            ("Subtitles", "captions.bubble", SettingsPanes.subtitles),
            ("Network", "network", SettingsPanes.network),
            ("Advanced", "wrench.and.screwdriver", SettingsPanes.advanced)
        ]
        for (title, symbol, build) in panes {
            let pane = SettingsPaneController(title: title, build: build)
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.center()
    }

    override func showWindow(_ sender: Any?) {
        for item in tabs.tabViewItems {
            item.viewController?.view.refreshBoundControls()
        }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func show(pane title: String) {
        if let index = tabs.tabViewItems.firstIndex(where: { $0.label == title }) {
            tabs.selectedTabViewItemIndex = index
        }
        showWindow(nil)
    }
}

/// One scrollable pane with a fixed width; height follows its content.
@MainActor
final class SettingsPaneController: NSViewController {
    private let build: () -> [NSView]
    static let width: CGFloat = 620

    init(title: String, build: @escaping () -> [NSView]) {
        self.build = build
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let stack = NSStackView(views: build())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.refreshBoundControls()
        preferredContentSize = view.fittingSize
    }
}

@MainActor
enum SettingsPanes {
    private static var settings: SettingsStore { SettingsStore.shared }

    // MARK: General

    static func general() -> [NSView] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "-"
        return [
            Form.section(
                "Playback",
                rows: [
                    Form.row(
                        "Resume where you left off",
                        control: Form.toggle(
                            { settings.rememberLastPosition }, { settings.rememberLastPosition = $0 })),
                    Form.row(
                        "Play next item automatically",
                        control: Form.toggle(
                            { settings.autoplayNext }, { settings.autoplayNext = $0 })),
                    Form.row(
                        "Repeat",
                        control: Form.popup(
                            [("Off", RepeatMode.off), ("All items", .all), ("Current item", .one)],
                            { settings.repeatMode }, { settings.repeatMode = $0 })),
                    Form.row("Shuffle", control: Form.toggle({ settings.shuffle }, { settings.shuffle = $0 }))
                ]),
            Form.section(
                "Window",
                rows: [
                    Form.row(
                        "Video size", detail: "How video fills the window when its shape differs.",
                        control: Form.popup(
                            [("Fit", VideoGravityPreference.aspect), ("Fill (crop edges)", .fill), ("Stretch", .stretch)],
                            { settings.videoGravity }, { settings.videoGravity = $0 }))
                ]),
            Form.section(
                "Updates",
                rows: [
                    Form.row(
                        "Check for updates automatically",
                        control: Form.toggle(
                            { settings.checkForUpdates }, { settings.checkForUpdates = $0 })),
                    Form.row(
                        "Lumora \(version) (build \(build))",
                        control: Form.button("Check Now") {
                            Updater.shared.checkForUpdates()
                        })
                ])
        ]
    }

    // MARK: Video

    static func video() -> [NSView] {
        let percent: (Double) -> String = { value in
            let number = Int((value * 100).rounded())
            return number == 0 ? "0%" : String(format: "%+d%%", number)
        }
        let relative: (Double) -> String = { value in percent(value - 1) }
        var pictureRows: [NSView] = []
        let picture = Form.section(
            "Picture",
            footnote: "Applies immediately to every open player window.",
            rows: [
                Form.row(
                    "Brightness",
                    control: Form.slider(
                        range: -1...1, step: 0.01, format: percent,
                        { settings.brightness }, { settings.brightness = $0 })),
                Form.row(
                    "Contrast",
                    control: Form.slider(
                        range: 0...2, step: 0.01, format: relative,
                        { settings.contrast }, { settings.contrast = $0 })),
                Form.row(
                    "Saturation",
                    control: Form.slider(
                        range: 0...2, step: 0.01, format: relative,
                        { settings.saturation }, { settings.saturation = $0 }))
            ]
        )
        pictureRows.append(picture)
        let reset = Form.button("Reset Picture") {
            settings.brightness = 0
            settings.contrast = 1
            settings.saturation = 1
            picture.refreshBoundControls()
        }
        return [
            Form.section(
                "Rendering",
                footnote:
                    "Metal uses libplacebo with HDR output and higher-quality scaling. OpenGL is a compatibility fallback; Lumora switches to it automatically if Metal can't start. Renderer changes apply to new player windows.",
                rows: [
                    Form.row(
                        "Renderer",
                        control: Form.popup(
                            VideoRenderer.allCases.map { ($0.title, $0) },
                            { settings.renderer }, { settings.renderer = $0 })),
                    Form.row(
                        "Hardware decoding", detail: "Uses the Mac's media engine for lower CPU use and longer battery life.",
                        control: Form.toggle({ settings.hardwareDecoding }, { settings.hardwareDecoding = $0 }))
                ]
            ),
            picture,
            Form.hStack([NSView(), reset])
        ]
    }

    // MARK: Audio

    static func audio() -> [NSView] {
        let equalizer = EqualizerView { settings.equalizerGains }
        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        let presets = EqualizerPreset.allCases
        preset.addItems(withTitles: presets.map(\.rawValue) + ["Custom"])
        let syncPreset = { [weak preset] in
            guard let preset else { return }
            if let match = EqualizerPreset.matching(settings.equalizerGains),
                let index = presets.firstIndex(of: match)
            {
                preset.selectItem(at: index)
            } else {
                preset.selectItem(withTitle: "Custom")
            }
        }
        syncPreset()
        let presetTrampoline = Trampoline {
            let index = preset.indexOfSelectedItem
            guard presets.indices.contains(index) else { return }
            settings.equalizerGains = presets[index].gains
            equalizer.show(presets[index].gains)
        }
        preset.target = presetTrampoline
        preset.action = #selector(Trampoline.fire)
        objc_setAssociatedObject(preset, &Trampoline.key, presetTrampoline, .OBJC_ASSOCIATION_RETAIN)
        equalizer.onChange = { gains in
            settings.equalizerGains = gains
            syncPreset()
        }

        let equalizerRow = NSView()
        equalizerRow.translatesAutoresizingMaskIntoConstraints = false
        equalizerRow.addSubview(equalizer)
        NSLayoutConstraint.activate([
            equalizer.leadingAnchor.constraint(equalTo: equalizerRow.leadingAnchor),
            equalizer.trailingAnchor.constraint(equalTo: equalizerRow.trailingAnchor),
            equalizer.topAnchor.constraint(equalTo: equalizerRow.topAnchor),
            equalizer.bottomAnchor.constraint(equalTo: equalizerRow.bottomAnchor)
        ])

        return [
            Form.section(
                "Volume",
                rows: [
                    Form.row(
                        "Volume", detail: "Also changed with the player's volume control.",
                        control: Form.slider(
                            range: 0...1, step: 0.01,
                            format: { "\(Int(($0 * 100).rounded()))%" },
                            { Double(settings.volume) }, { settings.volume = Float($0) }))
                ]),
            Form.section(
                "Equalizer", footnote: "Ten bands from 31 Hz to 16 kHz, ±12 dB.",
                rows: [
                    Form.row(
                        "Preset",
                        control: Form.hStack([
                            preset,
                            Form.button("Reset") {
                                settings.equalizerGains = EqualizerPreset.flat.gains
                                equalizer.show(EqualizerPreset.flat.gains)
                                syncPreset()
                            }
                        ])),
                    equalizerRow
                ])
        ]
    }

    // MARK: Subtitles

    static func subtitles() -> [NSView] {
        let appearance = Form.section(
            "Appearance",
            rows: [
                Form.row(
                    "Text size",
                    control: Form.slider(
                        range: 14...48, step: 1, format: { "\(Int($0)) pt" },
                        { settings.subtitleSize }, { settings.subtitleSize = $0 })),
                Form.row(
                    "Delay", detail: "Positive values show subtitles later.",
                    control: Form.slider(
                        range: -10...10, step: 0.1, format: { String(format: "%+.1f s", $0) },
                        { settings.subtitleDelay }, { settings.subtitleDelay = $0 }))
            ])
        return [
            appearance,
            Form.hStack([
                NSView(),
                Form.button("Reset Appearance") {
                    settings.subtitleSize = 24
                    settings.subtitleDelay = 0
                    appearance.refreshBoundControls()
                }
            ]),
            Form.section(
                "OpenSubtitles",
                footnote: "Your API key is stored in the macOS Keychain. Auto-download searches by the video's file name only.",
                rows: [
                    Form.row(
                        "Download subtitles automatically",
                        control: Form.toggle(
                            { settings.autoDownloadSubtitles }, { settings.autoDownloadSubtitles = $0 })),
                    Form.row(
                        "Languages", detail: "Comma-separated codes, e.g. en, es, fr",
                        control: Form.textField(
                            placeholder: "en", width: 180, { settings.subtitleLanguages }, { settings.subtitleLanguages = $0 })),
                    Form.row(
                        "API key",
                        control: Form.textField(
                            placeholder: "Paste your API key", secure: true, width: 220,
                            { settings.openSubtitlesAPIKey }, { settings.openSubtitlesAPIKey = $0 })),
                    Form.row(
                        "Don't have a key?",
                        control: Form.button("Get a Free API Key") {
                            if let url = URL(string: "https://www.opensubtitles.com/en/consumers") {
                                NSWorkspace.shared.open(url)
                            }
                        })
                ]
            )
        ]
    }

    // MARK: Network

    static func network() -> [NSView] {
        [
            toolSection(
                title: "YouTube and websites",
                footnote: "Lumora uses yt-dlp to play links from YouTube and other sites. Install it with: brew install yt-dlp",
                label: "yt-dlp",
                get: { settings.ytDLPPath },
                set: { settings.ytDLPPath = $0 }
            ),
            toolSection(
                title: "Converter",
                footnote: "Tools → Convert Media uses ffmpeg. Install it with: brew install ffmpeg",
                label: "ffmpeg",
                get: { settings.ffmpegPath },
                set: { settings.ffmpegPath = $0 }
            )
        ]
    }

    private static func toolSection(
        title: String,
        footnote: String,
        label: String,
        get: @escaping () -> String,
        set: @escaping (String) -> Void
    ) -> NSView {
        let status = Form.valueLabel("")
        let updateStatus = {
            let found = FileManager.default.isExecutableFile(atPath: get())
            status.stringValue = found ? "✓ Found" : "Not found"
            status.textColor = found ? .systemGreen : .systemOrange
        }
        updateStatus()
        let field = Form.textField(placeholder: "/opt/homebrew/bin/\(label)", width: 240, get) { value in
            set(value)
            updateStatus()
        }
        let choose = Form.button("Choose…") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            set(url.path)
            field.stringValue = url.path
            updateStatus()
        }
        return Form.section(
            title, footnote: footnote,
            rows: [
                Form.row("\(label) location", control: Form.hStack([field, choose])),
                Form.row("Status", control: status)
            ])
    }

    // MARK: Advanced

    static func advanced() -> [NSView] {
        let reveal: (URL) -> Void = { url in
            AppPaths.ensureDirectories()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return [
            Form.section(
                "Folders",
                rows: [
                    Form.row("Screenshots", control: Form.button("Show in Finder") { reveal(AppPaths.screenshots) }),
                    Form.row(
                        "Crash logs", detail: "Stored only on this Mac.",
                        control: Form.button("Show in Finder") {
                            reveal(AppPaths.logs)
                        }),
                    Form.row("Library and caches", control: Form.button("Show in Finder") { reveal(AppPaths.applicationSupport) })
                ]),
            Form.section(
                "About",
                rows: [
                    Form.row(
                        "Third-party licenses",
                        control: Form.button("View") {
                            if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                    Form.row(
                        "Source code and releases",
                        control: Form.button("Open GitHub") {
                            if let url = URL(string: "https://github.com/amegh-ts/lumora") {
                                NSWorkspace.shared.open(url)
                            }
                        })
                ]),
            Form.section(
                "Reset", footnote: "Restores every setting to its default. Your library, bookmarks and API key are kept.",
                rows: [
                    Form.row(
                        "Reset all settings",
                        control: Form.button("Reset…") {
                            let alert = NSAlert()
                            alert.messageText = "Reset all settings?"
                            alert.informativeText = "Every preference returns to its default. Your library, bookmarks and OpenSubtitles API key are kept."
                            alert.addButton(withTitle: "Reset")
                            alert.addButton(withTitle: "Cancel")
                            alert.buttons.first?.hasDestructiveAction = true
                            guard let window = SettingsWindowController.shared.window else { return }
                            alert.beginSheetModal(for: window) { response in
                                guard response == .alertFirstButtonReturn else { return }
                                MainActor.assumeIsolated {
                                    settings.resetToDefaults()
                                    SettingsWindowController.shared.window?.contentView?.refreshBoundControls()
                                }
                            }
                        })
                ])
        ]
    }
}

/// Retained closure target for controls that aren't Bound* subclasses.
final class Trampoline: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        action()
    }
}
