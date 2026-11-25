import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class PlayerViewController: NSViewController, PlayerRootViewDelegate, PlaylistSidebarDelegate, NSMenuItemValidation {
    let engine: PlaybackEngine
    let playlist: PlaylistStore
    let settings: SettingsStore
    let library: LibraryStore

    private let rootView = PlayerRootView(frame: NSRect(x: 0, y: 0, width: 1120, height: 700))
    private let videoView: VideoView
    let controls = ControlsOverlay(frame: .zero)
    private let titleBar = TitleOverlayView(frame: .zero)
    private let emptyState = EmptyStateView(frame: .zero)
    private let audioArtwork = AudioArtworkView(frame: .zero)
    private let miniControls = MiniControlsView(frame: .zero)
    let channelPanel = ChannelPanel()
    let channelBanner = ChannelBanner(frame: .zero)
    var liveTV = LiveTVState()
    var channelDigits = ""
    var channelDigitWork: DispatchWorkItem?
    var channelSkipWork: DispatchWorkItem?
    var controlsLeadingForPanel: NSLayoutConstraint!
    var liveTVUnloadWork: DispatchWorkItem?
    var continueChannelCancellable: AnyCancellable?
    var bannerLeadingForPanel: NSLayoutConstraint!
    private lazy var pictureInPicture = makePictureInPicture()
    private var hasPictureInPicture = false
    private let pipPlaceholder = NSStackView()
    private var snapWork: DispatchWorkItem?
    private var isSnapping = false
    private var isMiniPlayer: Bool { miniPlayerRestoreFrame != nil }
    let osd = OSDView(frame: .zero)
    private let thumbnail = ThumbnailPreviewView(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let loadingLabel = HUD.label(size: 12, weight: .medium, color: HUD.secondaryText)
    private var showingEmptyState: Bool?
    private var equalizerWork: DispatchWorkItem?
    private var lastActivity = Date()
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private lazy var sidebar = PlaylistSidebar(store: playlist)

    private var thumbnailX: NSLayoutConstraint!
    private var controlsTrailing: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()
    private var hideTimer: Timer?
    private var chromeVisible = true
    private var lastSavedTime: TimeInterval = 0
    private var watchedMarked = false
    private var resizedForCurrentFile = false
    private var thumbnailToken = 0
    private var scrollAccumulator: CGFloat = 0
    var miniPlayerRestoreFrame: NSRect?
    private var pendingSubtitles: [URL] = []
    private var suspendVideoWork: DispatchWorkItem?
    /// How long the window must stay hidden before video is suspended to free GPU memory.
    static let hiddenSuspendDelay: TimeInterval = 5

    var playlistCount: Int { playlist.items.count }
    var debugPlaylistTitles: [String] { playlist.items.map(\.title) }
    var debugPlaylistIndex: Int? { playlist.currentIndex }
    var areControlsShowing: Bool { chromeVisible && !controls.isHidden }

    var windowController: MainWindowController? {
        view.window?.windowController as? MainWindowController
    }

    init(engine: PlaybackEngine, playlist: PlaylistStore, settings: SettingsStore, library: LibraryStore) {
        self.engine = engine
        self.playlist = playlist
        self.settings = settings
        self.library = library
        self.videoView = VideoView(engine: engine)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = rootView
        rootView.appearance = NSAppearance(named: .darkAqua)
        rootView.eventDelegate = self
        installViews()
        installBindings()
        applySettings()
        refreshEmptyState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(rootView)
        setChromeVisible(true, animated: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if hasPictureInPicture {
            pictureInPicture.layout()
        }
    }

    func tearDown() {
        if hasPictureInPicture {
            pictureInPicture.tearDown()
        }
        NowPlayingService.shared.playerDidClose(self)
        hideTimer?.invalidate()
        saveProgress(force: true)
        videoView.tearDown()
        engine.shutdown()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func installViews() {
        for subview in [
            videoView, audioArtwork, emptyState, titleBar, spinner, loadingLabel, osd, sidebar, channelPanel, channelBanner, controls, miniControls, thumbnail
        ] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(subview)
        }
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        sidebar.isHidden = true
        sidebar.delegate = self
        audioArtwork.isHidden = true
        miniControls.isHidden = true
        miniControls.alphaValue = 0

        let maxWidth = controls.widthAnchor.constraint(lessThanOrEqualToConstant: 780)
        let preferredWidth = controls.widthAnchor.constraint(equalToConstant: 780)
        preferredWidth.priority = NSLayoutConstraint.Priority(rawValue: 400)
        controlsTrailing = controls.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -18)
        let centered = controls.centerXAnchor.constraint(equalTo: rootView.centerXAnchor)
        centered.priority = NSLayoutConstraint.Priority(rawValue: 450)
        thumbnailX = thumbnail.centerXAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 0)
        controlsLeadingForPanel = controls.leadingAnchor.constraint(greaterThanOrEqualTo: channelPanel.trailingAnchor, constant: 12)
        bannerLeadingForPanel = channelBanner.leadingAnchor.constraint(equalTo: channelPanel.trailingAnchor, constant: 14)
        let bannerLeading = channelBanner.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18)
        bannerLeading.priority = .defaultHigh
        let panelBottom = channelPanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -10)
        panelBottom.priority = NSLayoutConstraint.Priority(450)
        // The sidebar's content must not set a minimum window height (the mini player is small).
        let sidebarBottom = sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -10)
        sidebarBottom.priority = NSLayoutConstraint.Priority(450)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: rootView.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            miniControls.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            miniControls.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            miniControls.topAnchor.constraint(equalTo: rootView.topAnchor),
            miniControls.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            audioArtwork.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            audioArtwork.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            audioArtwork.topAnchor.constraint(equalTo: rootView.topAnchor),
            audioArtwork.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            emptyState.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: rootView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            titleBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 64),

            spinner.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
            loadingLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualTo: rootView.widthAnchor, constant: -80),

            osd.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            osd.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 48),

            controls.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 18),
            controlsTrailing,
            preferredWidth,
            maxWidth,
            centered,

            sidebar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -10),
            sidebar.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 40),
            sidebarBottom,
            sidebar.widthAnchor.constraint(equalToConstant: 290),

            thumbnail.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -6),

            channelPanel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 10),
            channelPanel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 40),
            panelBottom,
            channelPanel.widthAnchor.constraint(equalToConstant: 360),

            bannerLeading,
            channelBanner.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            channelBanner.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -18),
            thumbnailX
        ])

        controls.onAction = { [weak self] action in self?.handle(action) }
        installLiveTV()
        controls.menuProvider = { [weak self] kind in self?.menu(for: kind) ?? NSMenu() }
        let pipIcon = NSImageView(image: NSImage(systemSymbolName: "pip", accessibilityDescription: nil) ?? NSImage())
        pipIcon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        pipIcon.contentTintColor = HUD.secondaryText
        let pipLabel = HUD.label(size: 14, weight: .medium, color: HUD.secondaryText)
        pipLabel.stringValue = "Playing in Picture in Picture"
        let pipReturn = NSButton(title: "Return to Window", target: self, action: #selector(togglePictureInPicture(_:)))
        pipReturn.bezelStyle = .rounded
        for view in [pipIcon, pipLabel, pipReturn] as [NSView] {
            pipPlaceholder.addArrangedSubview(view)
        }
        pipPlaceholder.orientation = .vertical
        pipPlaceholder.spacing = 12
        pipPlaceholder.isHidden = true
        pipPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(pipPlaceholder, positioned: .above, relativeTo: audioArtwork)
        NSLayoutConstraint.activate([
            pipPlaceholder.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            pipPlaceholder.centerYAnchor.constraint(equalTo: rootView.centerYAnchor, constant: -30)
        ])
        miniControls.onTogglePlayback = { [weak self] in self?.engine.togglePlayback() }
        miniControls.onSkip = { [weak self] in self?.engine.skip($0) }
        miniControls.onScrub = { [weak self] time, finished in self?.engine.seek(to: time, exact: finished) }
        miniControls.onExpand = { [weak self] in self?.toggleMiniPlayer(nil) }
        miniControls.onClose = { [weak self] in self?.view.window?.performClose(nil) }
        emptyState.onOpenFile = { [weak self] in self?.chooseFiles() }
        emptyState.onLiveTV = { [weak self] in self?.setChannelPanel(visible: true) }
        emptyState.onContinueChannel = { [weak self] in self?.continueLastChannel() }
        emptyState.onOpenURL = { [weak self] in self?.windowController?.promptForURL() }
        emptyState.onOpenRecent = { [weak self] url in self?.windowController?.open([url]) }
    }

    private func installBindings() {
        engine.$currentTime
            .combineLatest(engine.$duration)
            .sink { [weak self] time, duration in
                guard let self else { return }
                if self.chromeVisible {
                    if self.isMiniPlayer {
                        self.miniControls.update(time: time, duration: duration)
                    } else {
                        self.controls.update(time: time, duration: duration)
                    }
                }
                self.saveProgress(force: false)
                NowPlayingService.shared.playerDidUpdateTime(self)
                if self.hasPictureInPicture, self.pictureInPicture.isActive {
                    self.pictureInPicture.syncTimebase()
                }
            }
            .store(in: &cancellables)

        engine.$bufferedRanges
            .sink { [weak self] in self?.controls.update(buffered: $0) }
            .store(in: &cancellables)

        engine.$hasPicture
            .combineLatest(engine.$hasMedia, engine.$mediaTags, engine.$isLive)
            .sink { [weak self] hasPicture, hasMedia, tags, isLive in
                guard let self else { return }
                self.controls.update(isLive: isLive)
                let show = hasMedia && !hasPicture
                if show {
                    self.audioArtwork.update(title: self.engine.currentItem?.title ?? "", tags: tags, isLive: isLive)
                }
                if self.audioArtwork.isHidden == show {
                    self.audioArtwork.isHidden = !show
                }
                DispatchQueue.main.async { self.updateAspectLock() }
            }
            .store(in: &cancellables)

        engine.$rotation
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateAspectLock() } }
            .store(in: &cancellables)

        engine.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                self.controls.update(isPlaying: isPlaying)
                self.miniControls.update(isPlaying: isPlaying)
                if self.hasPictureInPicture, self.pictureInPicture.isActive {
                    DispatchQueue.main.async { self.pictureInPicture.syncTimebase() }
                }
                if isPlaying {
                    NowPlayingService.shared.playerDidStartPlaying(self)
                } else {
                    NowPlayingService.shared.playerDidChange(self)
                }
                if isPlaying {
                    // @Published fires before the value changes; schedule once engine.isPlaying is true.
                    DispatchQueue.main.async { [weak self] in self?.scheduleHide() }
                } else {
                    self.setChromeVisible(true, animated: true)
                    self.saveProgress(force: true)
                }
            }
            .store(in: &cancellables)

        engine.$volume
            .combineLatest(engine.$isMuted)
            .sink { [weak self] volume, muted in
                self?.controls.update(volume: volume, muted: muted)
            }
            .store(in: &cancellables)

        engine.$duration
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                NowPlayingService.shared.playerDidChange(self)
            }
            .store(in: &cancellables)

        engine.$rate
            .removeDuplicates()
            .sink { [weak self] rate in
                guard let self else { return }
                self.controls.update(rate: rate)
                NowPlayingService.shared.playerDidChange(self)
            }
            .store(in: &cancellables)

        engine.$loopA
            .combineLatest(engine.$loopB, engine.$chapters)
            .sink { [weak self] a, b, chapters in
                self?.controls.update(loopA: a, loopB: b, chapters: chapters)
            }
            .store(in: &cancellables)

        engine.$hasMedia
            .combineLatest(engine.$isBuffering, engine.$statusMessage)
            .sink { [weak self] hasMedia, buffering, status in
                guard let self else { return }
                let loading = hasMedia && (buffering || status.hasPrefix("Opening"))
                loading ? self.spinner.startAnimation(nil) : self.spinner.stopAnimation(nil)
                self.loadingLabel.stringValue = buffering && !status.hasPrefix("Opening") ? "Buffering…" : status
                self.loadingLabel.isHidden = !loading
                self.refreshEmptyState()
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .combineLatest(engine.$subtitleTracks, engine.$hasMedia)
            // @Published fires before the new value is stored; read the engine after it lands.
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshControlState() } }
            .store(in: &cancellables)

        engine.$videoSize
            .removeDuplicates()
            // Width and height arrive separately and @Published fires before storing: size from
            // the engine on the next turn, once both have landed.
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fitWindow(to: self.engine.videoSize)
                }
            }
            .store(in: &cancellables)

        playlist.$items
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.sidebar.isHidden {
                    self.sidebar.reload()
                }
                self.refreshControlState()
            }
            .store(in: &cancellables)

        library.$records
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.engine.hasMedia else { return }
                self.emptyState.setRecent(self.library.continueWatching(limit: 4).filter { $0.url.isFileURL })
            }
            .store(in: &cancellables)

        installSettingsBindings()

        engine.onTitleChange = { [weak self] item in
            guard let self else { return }
            self.titleBar.title = item.title
            self.view.window?.title = item.title
            self.playlist.rename(id: item.id, to: item.title)
            if !self.sidebar.isHidden {
                self.sidebar.reload()
            }
            NowPlayingService.shared.playerDidUpdateTime(self)
        }
        engine.onLoad = { [weak self] item in
            guard let self else { return }
            if item.kind != .channel {
                self.liveTV.direction = 0
                self.scheduleLiveTVUnload()
                self.controls.setChannelMode(false)
                self.channelBanner.hide()
                self.channelPanel.playingKey = nil
            } else {
                self.updateChannelControls()
            }
            self.lastSavedTime = 0
            self.watchedMarked = false
            self.resizedForCurrentFile = false
            self.emptyState.setError(nil)
            self.titleBar.title = item.title
            self.view.window?.title = item.title
            if !self.sidebar.isHidden {
                self.sidebar.reload()
            }
        }
        engine.onFileLoaded = { [weak self] item in
            guard let self else { return }
            if item.kind == .channel {
                self.channelDidLoad()
            }
            self.applySettings()
            NowPlayingService.shared.playerDidChange(self)
            if !self.pendingSubtitles.isEmpty {
                let subtitles = self.pendingSubtitles
                self.pendingSubtitles = []
                self.addSubtitles(subtitles, forNextFile: false)
            }
            if self.settings.autoDownloadSubtitles, item.url.isFileURL {
                self.autoDownloadSubtitles(for: item)
            }
        }
        engine.onFinish = { [weak self] in self?.handleFinish() }
        engine.onError = { [weak self] message in
            guard let self else { return }
            self.emptyState.setError(message)
            self.pendingSubtitles = []
            self.refreshEmptyState()
            // A dead channel: say so; channel up/down may move on after a countdown.
            if self.liveTV.current != nil, self.engine.currentItem?.kind == .channel {
                self.emptyState.setError(
                    "“\(self.liveTV.current?.name ?? "This channel")” isn't available right now. Free channels often go offline or are blocked in some countries. Try another with ⌘↑ / ⌘↓ or the Live TV panel (⇧⌘T)."
                )
                self.channelDidFail()
                return
            }
            let hasNext = (self.playlist.currentIndex ?? 0) + 1 < self.playlist.items.count
            if hasNext {
                self.osd.show("Couldn't play — skipping to next", symbol: "exclamationmark.triangle.fill", duration: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.engine.hasMedia else { return }
                    self.windowController?.playNext(auto: false)
                }
            } else {
                self.osd.show("Couldn't play this file", symbol: "exclamationmark.triangle.fill", duration: 2.5)
            }
        }
        engine.onRendererFailure = { [weak self] in
            guard let self else { return }
            self.videoView.fallBackToOpenGL()
            self.osd.show("Metal unavailable — using OpenGL", symbol: "exclamationmark.triangle.fill", duration: 2.5)
        }
        engine.onScreenshot = { [weak self] url in
            guard let self else { return }
            if let url {
                self.osd.show("Screenshot saved", symbol: "camera.fill")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                self.osd.show("Screenshot failed", symbol: "exclamationmark.triangle.fill")
            }
        }

        NotificationCenter.default.publisher(for: .lumoraDidDownloadSubtitle)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let track = note.object as? SubtitleTrack, let url = track.url,
                    self.view.window?.isMainWindow == true, self.engine.hasMedia
                else { return }
                self.engine.addSubtitle(url)
                self.osd.show("Subtitle added: \(track.title)", symbol: "captions.bubble.fill")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.view.window else { return }
                self.windowVisibilityChanged(visible: window.occlusionState.contains(.visible))
            }
            .store(in: &cancellables)

        // Mini player: after a drag ends, glide to the nearest screen corner.
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .sink { [weak self] note in
                guard let self, self.isMiniPlayer, !self.isSnapping, (note.object as? NSWindow) === self.view.window else { return }
                self.scheduleSnap()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
            .sink { [weak self] _ in self?.refreshControlState() }
            .store(in: &cancellables)
    }

    /// Pushes every setting once (new file). Later changes arrive one property at a time through
    /// `installSettingsBindings`, so a volume tick doesn't re-send the whole configuration to mpv.
    /// Volume isn't pushed: each window keeps its own; Settings' volume is the default for new ones.
    private func applySettings() {
        engine.setGravity(settings.videoGravity)
        engine.setVideoAdjustments(brightness: settings.brightness, contrast: settings.contrast, saturation: settings.saturation)
        engine.setSubtitleScale(settings.subtitleSize / 24)
        engine.defaultSubtitleDelay = settings.subtitleDelay
        engine.setHardwareDecoding(settings.hardwareDecoding)
        engine.setEqualizer(settings.equalizerGains)
        applySubtitleStyle()
        engine.setPreferredLanguages(audio: settings.preferredAudioLanguages, subtitles: settings.preferredSubtitleLanguages)
        engine.setVolumeBoost(settings.volumeBoost)
        controls.setVolumeMax(engine.maxVolume)
        playlist.shuffle = settings.shuffle
        playlist.repeatMode = settings.repeatMode
    }

    private func applySubtitleStyle() {
        engine.setSubtitleStyle(
            font: settings.subtitleFont, color: settings.subtitleColor,
            background: settings.subtitleBackground, position: settings.subtitlePosition)
    }

    private func installSettingsBindings() {
        settings.$subtitleFont.combineLatest(settings.$subtitleColor, settings.$subtitleBackground, settings.$subtitlePosition)
            .dropFirst()
            // @Published fires before storing; read the settings on the next turn.
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applySubtitleStyle() } }
            .store(in: &cancellables)
        settings.$preferredAudioLanguages.combineLatest(settings.$preferredSubtitleLanguages).dropFirst()
            .sink { [weak self] audio, subtitles in self?.engine.setPreferredLanguages(audio: audio, subtitles: subtitles) }
            .store(in: &cancellables)
        settings.$volumeBoost.removeDuplicates().dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.engine.setVolumeBoost(enabled)
                self.controls.setVolumeMax(self.engine.maxVolume)
                self.controls.update(volume: self.engine.volume, muted: self.engine.isMuted)
            }
            .store(in: &cancellables)
        // The saved output device may be unplugged; use it only when it's present.
        engine.$audioDevices
            .combineLatest(settings.$audioDevice)
            .sink { [weak self] devices, wanted in
                guard let self else { return }
                let target = devices.contains { $0.name == wanted } ? wanted : "auto"
                if target != self.engine.audioDevice {
                    self.engine.setAudioDevice(target)
                }
            }
            .store(in: &cancellables)
        settings.$videoGravity.removeDuplicates().dropFirst()
            .sink { [weak self] in
                self?.engine.setGravity($0)
                DispatchQueue.main.async { self?.updateAspectLock() }
            }
            .store(in: &cancellables)
        settings.$brightness.combineLatest(settings.$contrast, settings.$saturation).dropFirst()
            .sink { [weak self] in self?.engine.setVideoAdjustments(brightness: $0, contrast: $1, saturation: $2) }
            .store(in: &cancellables)
        settings.$subtitleSize.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.engine.setSubtitleScale($0 / 24) }
            .store(in: &cancellables)
        settings.$subtitleDelay.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.engine.defaultSubtitleDelay = $0 }
            .store(in: &cancellables)
        settings.$hardwareDecoding.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.engine.setHardwareDecoding($0) }
            .store(in: &cancellables)
        settings.$equalizerGains.removeDuplicates().dropFirst()
            .sink { [weak self] gains in
                // Rebuilding the audio filter chain on every slider tick causes dropouts.
                self?.equalizerWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.engine.setEqualizer(gains) }
                self?.equalizerWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
            .store(in: &cancellables)
        settings.$streamQuality.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.engine.setStreamHeightCap($0.maxHeight) }
            .store(in: &cancellables)
        settings.$shuffle.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.playlist.shuffle = $0 }
            .store(in: &cancellables)
        settings.$repeatMode.removeDuplicates().dropFirst()
            .sink { [weak self] in self?.playlist.repeatMode = $0 }
            .store(in: &cancellables)
    }

    func applyInitialVolume() {
        engine.setVolume(settings.volume)
    }

    // MARK: - State

    /// Switches between the empty state and the player; does nothing unless that actually changes,
    /// so background updates never make the controls reappear.
    private func refreshEmptyState() {
        let showEmpty = !engine.hasMedia
        guard showEmpty != showingEmptyState else { return }
        showingEmptyState = showEmpty
        emptyState.isHidden = !showEmpty
        if showEmpty {
            emptyState.setRecent(library.continueWatching(limit: 4).filter { $0.url.isFileURL })
            emptyState.setLastChannel(ChannelStore.lastChannelName)
            scheduleLiveTVUnload()
            titleBar.title = ""
            view.window?.title = "Lumora"
        }
        controls.isHidden = showEmpty
        setChromeVisible(true, animated: false)
        if engine.isPlaying {
            scheduleHide()
        }
    }

    private func refreshControlState() {
        let isFullscreen = view.window?.styleMask.contains(.fullScreen) ?? false
        controls.update(
            hasPlaylistNeighbours: playlist.items.count > 1,
            hasAudio: !engine.audioTracks.isEmpty,
            hasMedia: engine.hasMedia,
            isFullscreen: isFullscreen
        )
    }

    private var hasSizedWindow = false

    /// Resizes the window to a newly opened video, as the "Resize window" setting allows.
    private func fitWindow(to size: CGSize) {
        updateAspectLock()
        guard size.width > 0, size.height > 0, !resizedForCurrentFile else { return }
        resizedForCurrentFile = true
        switch settings.windowFit {
        case .never: return
        case .firstFile where hasSizedWindow: return
        default: break
        }
        if resizeWindow(toVideoScale: nil, maxFraction: 0.8, minWidth: 640) {
            hasSizedWindow = true
        }
    }

    /// Video size in points with rotation applied (one video pixel per point).
    private var orientedVideoSize: CGSize? {
        var size = engine.videoSize
        guard size.width > 0, size.height > 0 else { return nil }
        // Aspect Ratio and Crop change the shown shape; keep the height and adjust the width.
        if let aspect = engine.displayAspect {
            size.width = (size.height * aspect).rounded()
        }
        return engine.rotation % 180 != 0 ? CGSize(width: size.height, height: size.width) : size
    }

    /// After Aspect Ratio or Crop: lock the new shape and resize the window around it.
    func reshapeWindowForPicture() {
        updateAspectLock()
        guard let window = view.window, !window.styleMask.contains(.fullScreen), miniPlayerRestoreFrame == nil,
            let size = orientedVideoSize
        else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let target = NSSize(width: (content.height * size.width / size.height).rounded(), height: content.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: target))
        frame.origin.x = window.frame.midX - frame.width / 2
        window.setFrame(frame, display: true, animate: !reduceMotion)
    }

    /// scale nil = as large as fits within maxFraction of the screen (never upscaling past
    /// minWidth); otherwise the video at that scale, shrunk only if it would not fit.
    @discardableResult
    private func resizeWindow(toVideoScale scale: CGFloat?, maxFraction: CGFloat, minWidth: CGFloat = 0) -> Bool {
        guard let videoSize = orientedVideoSize, let window = view.window, !window.styleMask.contains(.fullScreen),
            miniPlayerRestoreFrame == nil, let screen = window.screen ?? NSScreen.main
        else { return false }
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: .zero).size
        let maxSize = CGSize(width: visible.width * maxFraction - chrome.width, height: visible.height * maxFraction - chrome.height)
        let aspect = videoSize.width / videoSize.height
        var content: CGSize
        if let scale {
            content = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        } else {
            let fit = min(1, maxSize.width / videoSize.width, maxSize.height / videoSize.height)
            content = CGSize(width: videoSize.width * fit, height: videoSize.height * fit)
            content.width = max(content.width, min(minWidth, maxSize.width))
            content.height = content.width / aspect
        }
        // Never larger than the screen; tall or portrait video fits by height.
        if content.width > maxSize.width {
            content = CGSize(width: maxSize.width, height: maxSize.width / aspect)
        }
        if content.height > maxSize.height {
            content = CGSize(width: maxSize.height * aspect, height: maxSize.height)
        }
        content.width = max(content.width, 320)
        content.height = max(content.height, 180)
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: oldFrame.midX - frame.width / 2, y: oldFrame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: !reduceMotion)
        return true
    }

    /// In Fit mode the window keeps the video's shape while resizing, so no black bars appear.
    /// Fill/Stretch, audio without a picture and the empty window resize freely.
    func updateAspectLock() {
        guard let window = view.window else { return }
        if settings.videoGravity == .aspect, engine.hasMedia, engine.hasPicture, let size = orientedVideoSize {
            window.contentAspectRatio = size
        } else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
    }

    @objc func halfSize(_ sender: Any?) { resizeWindow(toVideoScale: 0.5, maxFraction: 1) }
    @objc func actualSize(_ sender: Any?) { resizeWindow(toVideoScale: 1, maxFraction: 1) }
    @objc func doubleSize(_ sender: Any?) { resizeWindow(toVideoScale: 2, maxFraction: 1) }
    @objc func fitToScreen(_ sender: Any?) { resizeWindow(toVideoScale: 100, maxFraction: 1) }

    func saveProgress(force: Bool) {
        guard let item = engine.currentItem, engine.duration > 0 else { return }
        let time = engine.currentTime
        if engine.duration - time < 5 {
            if !watchedMarked {
                watchedMarked = true
                library.markWatched(url: item.url, title: item.title, duration: engine.duration)
            }
            return
        }
        guard time > 0, force || abs(time - lastSavedTime) >= 10 else { return }
        lastSavedTime = time
        // Watching again from the middle clears "watched" so resume works for this file again.
        library.update(url: item.url, title: item.title, resumeTime: time, duration: engine.duration, watched: false)
    }

    private func handleFinish() {
        guard let item = engine.currentItem else { return }
        // A live channel that stops has dropped out; don't mark it watched or move on.
        if item.kind == .channel {
            osd.show("The channel stopped broadcasting", symbol: "antenna.radiowaves.left.and.right.slash", duration: 2.5)
            return
        }
        if !watchedMarked {
            watchedMarked = true
            library.markWatched(url: item.url, title: item.title, duration: engine.duration)
        }
        if settings.autoplayNext || settings.repeatMode == .one {
            windowController?.playNext(auto: true)
        }
    }

    private func autoDownloadSubtitles(for item: PlaybackItem) {
        let apiKey = settings.openSubtitlesAPIKey
        guard !apiKey.isEmpty, engine.subtitleTracks.isEmpty else { return }
        let query = item.url.deletingPathExtension().lastPathComponent
        let languages = settings.subtitleLanguages
        let expected = item.id
        Task { @MainActor in
            let results = await OpenSubtitlesService.search(query: query, languages: languages, apiKey: apiKey)
            guard let result = results.first, self.engine.currentItem?.id == expected,
                let data = await OpenSubtitlesService.download(result: result, apiKey: apiKey),
                self.engine.currentItem?.id == expected,
                let track = SubtitleService.saveDownloaded(data, language: result.language, filename: result.title),
                let url = track.url
            else { return }
            self.engine.addSubtitle(url)
            self.osd.show("Subtitle downloaded", symbol: "captions.bubble.fill")
        }
    }

    // MARK: - Hidden-window memory release

    /// Minimized, on another Space or fully covered: after a short delay turn the video output off
    /// (audio continues) so its GPU memory is freed; bring it back as soon as the window shows.
    private func windowVisibilityChanged(visible: Bool) {
        if DebugMode.background { return }
        suspendVideoWork?.cancel()
        suspendVideoWork = nil
        if visible {
            engine.resumeVideo()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.view.window?.occlusionState.contains(.visible) == false else { return }
            // In Picture in Picture the video is still on screen, just not in this window.
            if self.hasPictureInPicture, self.pictureInPicture.isActive { return }
            self.engine.suspendVideo()
        }
        suspendVideoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenSuspendDelay, execute: work)
    }

    // MARK: - Chrome visibility

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        // The mini player swaps the control bar and title for its own compact controls.
        let mini = isMiniPlayer
        let showControls = visible && engine.hasMedia && !mini
        let showMini = visible && engine.hasMedia && mini
        chromeVisible = visible
        let duration = animated && !reduceMotion ? HUD.fadeDuration : 0
        if showControls {
            controls.isHidden = false
            controls.update(time: engine.currentTime, duration: engine.duration)
        }
        if showMini {
            miniControls.isHidden = false
            miniControls.update(time: engine.currentTime, duration: engine.duration)
            miniControls.update(isPlaying: engine.isPlaying)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            controls.animator().alphaValue = showControls ? 1 : 0
            titleBar.animator().alphaValue = showControls ? 1 : 0
            miniControls.animator().alphaValue = showMini ? 1 : 0
            if let buttons = view.window?.standardWindowButton(.closeButton)?.superview {
                buttons.animator().alphaValue = visible && !mini ? 1 : 0
            }
        } completionHandler: { [weak self] in
            // Fully hidden controls stop drawing and tracking the mouse.
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.chromeVisible || !self.engine.hasMedia || self.isMiniPlayer {
                    self.controls.isHidden = true
                }
                if !self.chromeVisible || !self.engine.hasMedia || !self.isMiniPlayer {
                    self.miniControls.isHidden = true
                }
            }
        }
        if !visible {
            thumbnail.hide()
            if engine.hasMedia, rootView.window?.isKeyWindow == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private static let hideDelay: TimeInterval = 2.5

    /// Called on every mouse move: only moves the existing timer's deadline instead of
    /// creating a new timer each time.
    private func scheduleHide() {
        lastActivity = Date()
        if !chromeVisible || (engine.hasMedia && controls.alphaValue < 1) {
            setChromeVisible(true, animated: true)
        }
        guard engine.isPlaying, !keepsControlsVisible else {
            hideTimer?.invalidate()
            hideTimer = nil
            return
        }
        if let hideTimer, hideTimer.isValid {
            hideTimer.fireDate = lastActivity.addingTimeInterval(Self.hideDelay)
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideTimer = nil
                guard self.engine.isPlaying else { return }
                if self.controls.isInteracting || !self.sidebar.isHidden {
                    self.scheduleHide()
                    return
                }
                self.setChromeVisible(false, animated: true)
            }
        }
    }

    /// Keep controls on screen for VoiceOver and Full Keyboard Access users.
    private var keepsControlsVisible: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || DebugMode.keepControls
    }

    // MARK: - Actions

    private func handle(_ action: ControlsAction) {
        scheduleHide()
        switch action {
        case .togglePlayback:
            engine.togglePlayback()
        case .previous:
            windowController?.playPrevious()
        case .next:
            windowController?.playNext(auto: false)
        case let .skip(seconds):
            engine.skip(seconds)
        case let .scrub(time, finished):
            engine.seek(to: time, exact: finished)
        case let .hover(time, x):
            showThumbnail(at: time, xInControls: x)
        case let .volume(value):
            engine.setVolume(value)
            settings.volume = value
        case .toggleMute:
            engine.toggleMute()
        case .toggleFullscreen:
            toggleFullscreen(self)
        case .togglePlaylist:
            togglePlaylist()
        case .toggleChannels:
            toggleChannelPanel(nil)
        }
    }

    private func showThumbnail(at time: TimeInterval?, xInControls: CGFloat) {
        guard let time, let item = engine.currentItem, engine.duration > 0 else {
            thumbnail.hide()
            return
        }
        let x = rootView.convert(NSPoint(x: xInControls, y: 0), from: controls).x
        thumbnailX.constant = min(max(x, 100), rootView.bounds.width - 100)
        let size = engine.videoSize
        let aspect = size.height > 0 ? size.width / size.height : 16 / 9
        let chapter = engine.chapters.last { $0.time <= time }?.title
        thumbnail.show(time: time, chapter: chapter, aspect: aspect)
        thumbnailToken += 1
        let token = thumbnailToken
        ThumbnailService.shared.request(url: item.url, time: time, duration: engine.duration) { [weak self] image in
            guard let self, self.thumbnailToken == token else { return }
            self.thumbnail.setImage(image, aspect: aspect)
        }
    }

    var isPlaylistVisible: Bool { !sidebar.isHidden }

    private func togglePlaylist() {
        let show = sidebar.isHidden
        sidebar.isHidden = !show
        controlsTrailing.constant = show ? -(290 + 20) : -18
        if show {
            sidebar.reload()
        }
    }

    private func chooseFiles() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose videos, audio, subtitles or a folder"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                self?.windowController?.open(urls)
            }
        }
    }

    func chooseSubtitleFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SubtitleService.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.engine.addSubtitle(url)
                self?.osd.show("Subtitle added", symbol: "captions.bubble.fill")
            }
        }
    }

    // MARK: - Menus

    private func menu(for kind: ControlsMenu) -> NSMenu {
        switch kind {
        case .speed: return speedMenu()
        case .audio: return audioMenu()
        case .subtitles: return subtitlesMenu()
        case .more: return moreMenu()
        }
    }

    private func speedMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addHeader("Speed")
        for speed: Float in [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4] {
            let title = speed == 1 ? "Normal" : String(format: "%g×", speed)
            menu.addItem(
                ClosureMenuItem(title, checked: abs(engine.rate - speed) < 0.01) { [weak self] in
                    self?.setSpeed(speed)
                })
        }
        return menu
    }

    private func audioMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addHeader("Audio Track")
        if engine.audioTracks.isEmpty {
            menu.addItem(ClosureMenuItem("No audio", enabled: false) {})
        }
        for track in engine.audioTracks {
            menu.addItem(
                ClosureMenuItem(track.displayName, checked: track.isSelected) { [weak self] in
                    self?.engine.selectAudioTrack(track.id)
                    self?.osd.show("Audio: \(track.displayName)", symbol: "speaker.wave.2.fill")
                })
        }
        menu.addItem(.separator())
        let delay = NSMenuItem(title: "Audio Delay: \(String(format: "%+.1f", engine.audioDelay)) s", action: nil, keyEquivalent: "")
        delay.submenu = delayMenu { [weak self] in self?.adjustAudioDelay($0) }
        menu.addItem(delay)
        let device = NSMenuItem(title: "Output Device", action: nil, keyEquivalent: "")
        let devices = NSMenu()
        fill(.audioDevice, into: devices)
        device.submenu = devices
        menu.addItem(device)
        menu.addItem(ClosureMenuItem("Volume Boost", checked: settings.volumeBoost) { [weak self] in self?.toggleVolumeBoost(nil) })
        menu.addItem(
            ClosureMenuItem("Equalizer…") {
                (NSApp.delegate as? AppDelegate)?.showAudioSettings(nil)
            })
        return menu
    }

    private func subtitlesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addHeader("Subtitles")
        menu.addItem(
            ClosureMenuItem("Off", checked: engine.selectedSubtitleTrackID == nil) { [weak self] in
                self?.engine.selectSubtitleTrack(nil)
                self?.osd.show("Subtitles off", symbol: "captions.bubble")
            })
        for track in engine.subtitleTracks {
            menu.addItem(
                ClosureMenuItem(track.displayName, checked: track.isSelected) { [weak self] in
                    self?.engine.selectSubtitleTrack(track.id)
                    self?.osd.show("Subtitles: \(track.displayName)", symbol: "captions.bubble.fill")
                })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Subtitle File…") { [weak self] in self?.chooseSubtitleFile() })
        menu.addItem(
            ClosureMenuItem("Search Subtitles Online…") {
                SubtitleSearchWindowController.shared.showWindow(nil)
            })
        menu.addItem(.separator())
        // The per-file delay lives in the engine; Settings only holds the default for new files.
        let delay = NSMenuItem(title: "Subtitle Delay: \(String(format: "%+.1f", engine.subtitleDelay)) s", action: nil, keyEquivalent: "")
        delay.submenu = delayMenu { [weak self] in self?.adjustSubtitleDelay($0) }
        menu.addItem(delay)
        return menu
    }

    private func delayMenu(_ adjust: @escaping (TimeInterval?) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Earlier by 0.1 s") { adjust(-0.1) })
        menu.addItem(ClosureMenuItem("Later by 0.1 s") { adjust(0.1) })
        menu.addItem(ClosureMenuItem("Earlier by 1 s") { adjust(-1) })
        menu.addItem(ClosureMenuItem("Later by 1 s") { adjust(1) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reset") { adjust(nil) })
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        if !engine.streamVariants.isEmpty {
            let current = engine.streamVariants.first(where: \.isSelected)?.label
            let parent = NSMenuItem(title: current.map { "Quality: \($0)" } ?? "Quality", action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: nil)
            let submenu = NSMenu()
            fill(.streamQuality, into: submenu)
            parent.submenu = submenu
            menu.addItem(parent)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Take Screenshot") { [weak self] in self?.takeScreenshot(nil) })
        menu.addItem(ClosureMenuItem("Picture in Picture") { [weak self] in self?.togglePictureInPicture(nil) })
        menu.addItem(ClosureMenuItem("Media Info") { [weak self] in self?.showMediaInfo(nil) })
        menu.addItem(ClosureMenuItem("Go to Time…") { [weak self] in self?.goToTime(nil) })
        menu.addItem(ClosureMenuItem("Add Bookmark") { [weak self] in self?.addBookmark() })
        if let item = engine.currentItem, let bookmarks = library.record(for: item.url)?.bookmarks, !bookmarks.isEmpty {
            let parent = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for bookmark in bookmarks {
                submenu.addItem(ClosureMenuItem(bookmark.label) { [weak self] in self?.engine.seek(to: bookmark.time) })
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        if !engine.chapters.isEmpty {
            let parent = NSMenuItem(title: "Chapters", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, chapter) in engine.chapters.enumerated() {
                let title = chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
                submenu.addItem(
                    ClosureMenuItem("\(title)  \(TimeFormatter.string(chapter.time))") { [weak self] in
                        self?.engine.seek(to: chapter.time)
                    })
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        let loopTitle: String
        if engine.loopA == nil {
            loopTitle = "Set Loop Start (A)"
        } else if engine.loopB == nil {
            loopTitle = "Set Loop End (B)"
        } else {
            loopTitle = "Clear A-B Loop"
        }
        menu.addItem(ClosureMenuItem(loopTitle) { [weak self] in self?.cycleABLoop(nil) })
        menu.addItem(ClosureMenuItem("Next Frame") { [weak self] in self?.engine.stepFrame(forward: true) })
        menu.addItem(ClosureMenuItem("Previous Frame") { [weak self] in self?.engine.stepFrame(forward: false) })
        menu.addItem(.separator())
        let aspect = NSMenuItem(title: "Video Size", action: nil, keyEquivalent: "")
        let aspectMenu = NSMenu()
        let titles: [(VideoGravityPreference, String)] = [(.aspect, "Fit"), (.fill, "Fill (crop)"), (.stretch, "Stretch")]
        for (preference, title) in titles {
            aspectMenu.addItem(
                ClosureMenuItem(title, checked: settings.videoGravity == preference) { [weak self] in
                    self?.settings.videoGravity = preference
                })
        }
        aspect.submenu = aspectMenu
        menu.addItem(aspect)
        menu.addItem(ClosureMenuItem("Rotate 90°") { [weak self] in self?.engine.rotate() })
        menu.addItem(.separator())
        let onTop = view.window?.level == .floating
        menu.addItem(ClosureMenuItem("Keep on Top", checked: onTop) { [weak self] in self?.toggleKeepOnTop(nil) })
        menu.addItem(
            ClosureMenuItem("Mini Player", checked: miniPlayerRestoreFrame != nil) { [weak self] in
                self?.toggleMiniPlayer(nil)
            })
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Video & Audio Settings…") {
                SettingsWindowController.shared.showWindow(nil)
            })
        return menu
    }

    func playerRootViewContextMenu(_ view: PlayerRootView) -> NSMenu? {
        guard engine.hasMedia else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(engine.isPlaying ? "Pause" : "Play") { [weak self] in self?.engine.togglePlayback() })
        menu.addItem(.separator())
        let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speed.submenu = speedMenu()
        menu.addItem(speed)
        let audio = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        audio.submenu = audioMenu()
        menu.addItem(audio)
        let subtitles = NSMenuItem(title: "Subtitles", action: nil, keyEquivalent: "")
        subtitles.submenu = subtitlesMenu()
        menu.addItem(subtitles)
        menu.addItem(.separator())
        for item in moreMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        return menu
    }

    func setSpeed(_ speed: Float) {
        engine.setRate(speed)
        osd.show(speed == 1 ? "Normal speed" : String(format: "Speed %g×", speed), symbol: "gauge.with.dots.needle.67percent")
    }

    /// Adjusts only the current file; the default in Settings applies to the next file.
    func adjustSubtitleDelay(_ delta: TimeInterval?) {
        engine.adjustSubtitleDelay(by: delta)
        osd.show(String(format: "Subtitle delay %+.1f s", engine.subtitleDelay), symbol: "captions.bubble")
    }

    func addBookmark() {
        guard let item = engine.currentItem else { return }
        library.addBookmark(url: item.url, time: engine.currentTime, label: TimeFormatter.string(engine.currentTime))
        osd.show("Bookmark added at \(TimeFormatter.string(engine.currentTime))", symbol: "bookmark.fill")
    }

    // MARK: - Root view events

    func playerRootViewDidMoveMouse(_ view: PlayerRootView) {
        scheduleHide()
    }

    func playerRootViewDidExit(_ view: PlayerRootView) {
        guard engine.isPlaying, !controls.isInteracting else { return }
        hideTimer?.invalidate()
        setChromeVisible(false, animated: true)
    }

    func playerRootViewDidSingleClick(_ view: PlayerRootView) {
        guard engine.hasMedia else { return }
        engine.togglePlayback()
    }

    func playerRootViewDidDoubleClick(_ view: PlayerRootView) {
        toggleFullscreen(self)
    }

    func playerRootView(_ view: PlayerRootView, didScrollX x: CGFloat, y: CGFloat, precise: Bool) {
        guard engine.hasMedia else { return }
        if abs(y) >= abs(x) {
            let step: Float = precise ? Float(y) / 300 : Float(y) * 0.02
            engine.setVolume(engine.volume + step)
            settings.volume = engine.volume
            osd.show("Volume \(Int((engine.volume * 100).rounded()))%", symbol: "speaker.wave.2.fill", duration: 0.8)
        } else {
            scrollAccumulator += precise ? x / 8 : x * 2
            if abs(scrollAccumulator) >= 1 {
                let seconds = scrollAccumulator.rounded(.towardZero)
                scrollAccumulator -= seconds
                engine.skip(TimeInterval(-seconds))
            }
        }
        scheduleHide()
    }

    func playerRootView(_ view: PlayerRootView, isDropTarget: Bool) {
        emptyState.setDropTarget(isDropTarget && !engine.hasMedia)
        if isDropTarget, engine.hasMedia {
            osd.show("Drop to play", symbol: "play.rectangle", duration: 1)
        }
    }

    func playerRootView(_ view: PlayerRootView, didReceiveURLs urls: [URL]) {
        windowController?.open(urls)
    }

    /// Adds subtitle files now, or after the next file loads when a video is being opened with them.
    func addSubtitles(_ urls: [URL], forNextFile: Bool) {
        if forNextFile {
            pendingSubtitles.append(contentsOf: urls)
            return
        }
        guard engine.hasMedia else {
            osd.show("Open a video first, then add subtitles", symbol: "captions.bubble", duration: 2)
            return
        }
        urls.forEach(engine.addSubtitle)
        osd.show(urls.count == 1 ? "Subtitle added" : "\(urls.count) subtitles added", symbol: "captions.bubble.fill")
    }

    func playerRootView(_ view: PlayerRootView, handleKeyDown event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control])
        guard modifiers.isEmpty else { return false }
        let big = event.modifierFlags.contains(.option)
        let fine = event.modifierFlags.contains(.shift)
        // Live TV: number keys tune like a remote; Page Up/Down change channel; ⌫ goes back;
        // I shows the channel banner.
        if let character = event.charactersIgnoringModifiers?.first, character.isASCII, character.isNumber,
            !ChannelStore.shared.all.isEmpty
        {
            enterChannelDigit(character)
            return true
        }
        if isWatchingChannel {
            var handled = true
            switch Int(event.keyCode) {
            case 116: stepChannel(1)
            case 121: stepChannel(-1)
            case 51: previousChannel(nil)
            default:
                if event.charactersIgnoringModifiers?.lowercased() == "i" {
                    showChannelInfo()
                } else {
                    handled = false
                }
            }
            if handled {
                scheduleHide()
                return true
            }
        }
        switch Int(event.keyCode) {
        case 123:
            engine.skip(big ? -60 : fine ? -3 : -10)
        case 124:
            engine.skip(big ? 60 : fine ? 3 : 10)
        case 126:
            changeVolume(by: 0.05)
        case 125:
            changeVolume(by: -0.05)
        case 53:
            if miniPlayerRestoreFrame != nil {
                toggleMiniPlayer(nil)
            } else if view.window?.styleMask.contains(.fullScreen) == true {
                view.window?.toggleFullScreen(nil)
            } else {
                return false
            }
        default:
            switch (event.charactersIgnoringModifiers ?? "").lowercased() {
            case " ", "k": engine.togglePlayback()
            case "f": toggleFullscreen(self)
            case "m": engine.toggleMute()
            case "s": takeScreenshot(nil)
            case "b": addBookmark()
            case "l": cycleABLoop(nil)
            case "p": togglePlaylist()
            case "t", "v": cycleSubtitles(nil)
            case "a": cycleAudio(nil)
            case "[": setSpeed(max(0.25, engine.rate - 0.25))
            case "]": setSpeed(min(4, engine.rate + 0.25))
            case "=": setSpeed(1)
            case ",": engine.stepFrame(forward: false)
            case ".": engine.stepFrame(forward: true)
            case "n": windowController?.playNext(auto: false)
            default: return false
            }
        }
        scheduleHide()
        return true
    }

    func changeVolume(by delta: Float) {
        engine.setVolume(engine.volume + delta)
        settings.volume = engine.volume
        osd.show("Volume \(Int((engine.volume * 100).rounded()))%", symbol: "speaker.wave.2.fill", duration: 0.8)
    }

    // MARK: - Playlist sidebar

    func playlistSidebar(_ sidebar: PlaylistSidebar, didSelect index: Int) {
        playlist.select(at: index)
        windowController?.playCurrent()
    }

    func playlistSidebarDidRequestAdd(_ sidebar: PlaylistSidebar) {
        chooseFiles()
    }

    func playlistSidebarDidRequestClear(_ sidebar: PlaylistSidebar) {
        saveProgress(force: true)
        engine.stop()
        playlist.clear()
        sidebar.reload()
    }

    func playlistSidebar(_ sidebar: PlaylistSidebar, didRequestRemove index: Int) {
        let removingCurrent = index == playlist.currentIndex
        playlist.remove(at: index)
        if removingCurrent {
            if playlist.current != nil {
                windowController?.playCurrent()
            } else {
                engine.stop()
            }
        }
        sidebar.reload()
    }

    // MARK: - Menu actions (responder chain)

    @objc func togglePlayback(_ sender: Any?) {
        engine.togglePlayback()
    }

    @objc func stopPlayback(_ sender: Any?) {
        saveProgress(force: true)
        engine.stop()
    }

    @objc func nextItem(_ sender: Any?) {
        windowController?.playNext(auto: false)
    }

    @objc func previousItem(_ sender: Any?) {
        windowController?.playPrevious()
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        if miniPlayerRestoreFrame != nil {
            toggleMiniPlayer(nil)
        }
        view.window?.toggleFullScreen(nil)
    }

    @objc func takeScreenshot(_ sender: Any?) {
        guard engine.hasMedia else { return }
        engine.screenshot()
    }

    @objc func togglePlaylist(_ sender: Any?) {
        togglePlaylist()
    }

    @objc func cycleSubtitles(_ sender: Any?) {
        let ids: [Int?] = [nil] + engine.subtitleTracks.map { Optional($0.id) }
        let current = ids.firstIndex { $0 == engine.selectedSubtitleTrackID } ?? 0
        let next = ids[(current + 1) % ids.count]
        engine.selectSubtitleTrack(next)
        let name = next.flatMap { id in engine.subtitleTracks.first { $0.id == id }?.displayName } ?? "Off"
        osd.show("Subtitles: \(name)", symbol: "captions.bubble")
    }

    @objc func cycleAudio(_ sender: Any?) {
        let tracks = engine.audioTracks
        guard tracks.count > 1 else { return }
        let current = tracks.firstIndex { $0.isSelected } ?? 0
        let next = tracks[(current + 1) % tracks.count]
        engine.selectAudioTrack(next.id)
        osd.show("Audio: \(next.displayName)", symbol: "speaker.wave.2.fill")
    }

    @objc func cycleABLoop(_ sender: Any?) {
        guard engine.hasMedia else { return }
        let message: String
        if engine.loopA == nil {
            message = "Loop start set"
        } else if engine.loopB == nil {
            message = "Looping A-B"
        } else {
            message = "Loop cleared"
        }
        engine.cycleABLoop()
        osd.show(message, symbol: "repeat")
    }

    @objc func cycleRepeatMode(_ sender: Any?) {
        let all = RepeatMode.allCases
        let current = all.firstIndex(of: settings.repeatMode) ?? 0
        settings.repeatMode = all[(current + 1) % all.count]
        let names: [RepeatMode: String] = [.off: "Repeat off", .all: "Repeat all", .one: "Repeat one"]
        osd.show(names[settings.repeatMode] ?? "", symbol: settings.repeatMode == .one ? "repeat.1" : "repeat")
    }

    @objc func toggleKeepOnTop(_ sender: Any?) {
        guard let window = view.window else { return }
        window.level = window.level == .floating ? .normal : .floating
        osd.show(window.level == .floating ? "Keep on top" : "Normal window", symbol: "pin.fill")
    }

    private func scheduleSnap() {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Still dragging: check again shortly.
                if NSEvent.pressedMouseButtons != 0 {
                    self.scheduleSnap()
                } else {
                    self.snapToCorner()
                }
            }
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func snapToCorner() {
        guard isMiniPlayer, let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        var frame = window.frame
        frame.origin.x = frame.midX < visible.midX ? visible.minX + margin : visible.maxX - frame.width - margin
        frame.origin.y = frame.midY < visible.midY ? visible.minY + margin : visible.maxY - frame.height - margin
        guard frame.origin != window.frame.origin else { return }
        isSnapping = true
        window.setFrame(frame, display: true, animate: !reduceMotion)
        isSnapping = false
    }

    private func makePictureInPicture() -> PictureInPicture {
        let pip = PictureInPicture(engine: engine)
        hasPictureInPicture = true
        pip.hostView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(pip.hostView, positioned: .above, relativeTo: videoView)
        NSLayoutConstraint.activate([
            pip.hostView.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            pip.hostView.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            pip.hostView.topAnchor.constraint(equalTo: videoView.topAnchor),
            pip.hostView.bottomAnchor.constraint(equalTo: videoView.bottomAnchor)
        ])
        pip.onActiveChange = { [weak self] active in
            guard let self else { return }
            self.pipPlaceholder.isHidden = !active
            if !active {
                self.osd.show("Back in the window", symbol: "pip.exit")
            }
        }
        pip.onRestore = { [weak self] in
            self?.view.window?.makeKeyAndOrderFront(nil)
            AppDelegate.activateApp()
        }
        return pip
    }

    /// View › Picture in Picture (⌥⌘P): the video floats above other apps in the system PiP window.
    @objc func togglePictureInPicture(_ sender: Any?) {
        if hasPictureInPicture, pictureInPicture.isActive {
            pictureInPicture.stop()
            return
        }
        guard engine.hasMedia, engine.hasPicture else { return }
        guard engine.renderer == .metal, !videoView.isUsingOpenGL else {
            osd.show("Picture in Picture needs the Metal renderer (Settings › Video)", symbol: "pip")
            return
        }
        guard PictureInPicture.isSupported else {
            osd.show("Picture in Picture isn't available on this Mac", symbol: "pip")
            return
        }
        leaveMiniPlayerIfNeeded()
        if view.window?.styleMask.contains(.fullScreen) == true {
            view.window?.toggleFullScreen(nil)
        }
        pictureInPicture.start()
    }

    /// DEBUG test hook: runs the PiP frame pipeline without the floating window.
    func debugPictureInPicture(start: Bool, frameFile: URL?) -> String {
        if start {
            pictureInPicture.start(dryRun: true)
            return "pip dry-run started"
        }
        let frames = pictureInPicture.framesRendered
        if let frameFile {
            pictureInPicture.debugSaveFrame(to: frameFile)
        }
        pictureInPicture.stop()
        return "pip dry-run stopped frames=\(frames)"
    }

    @objc func toggleMiniPlayer(_ sender: Any?) {
        guard let window = view.window else { return }
        if let restore = miniPlayerRestoreFrame {
            miniPlayerRestoreFrame = nil
            snapWork?.cancel()
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.minSize = NSSize(width: 420, height: 260)
            window.setFrame(restore, display: true, animate: !reduceMotion)
            setChromeVisible(true, animated: false)
            scheduleHide()
            return
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        setChannelPanel(visible: false)
        miniPlayerRestoreFrame = window.frame
        let size = orientedVideoSize ?? CGSize(width: 16, height: 9)
        let aspect = size.width / size.height
        let width: CGFloat = aspect < 1 ? 240 : 360
        let content = NSRect(x: 0, y: 0, width: width, height: width / aspect)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.minY + 20)
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.minSize = NSSize(width: 200, height: 112)
        isSnapping = true
        window.setFrame(frame, display: true, animate: !reduceMotion)
        isSnapping = false
        setChromeVisible(true, animated: false)
        scheduleHide()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleKeepOnTop(_:)):
            menuItem.state = view.window?.level == .floating ? .on : .off
            return true
        case #selector(toggleMiniPlayer(_:)):
            menuItem.state = miniPlayerRestoreFrame != nil ? .on : .off
            return engine.hasMedia || miniPlayerRestoreFrame != nil
        case #selector(togglePlayback(_:)), #selector(stopPlayback(_:)), #selector(takeScreenshot(_:)),
            #selector(cycleSubtitles(_:)), #selector(cycleAudio(_:)), #selector(cycleABLoop(_:)):
            return engine.hasMedia
        case #selector(nextItem(_:)), #selector(previousItem(_:)):
            return playlist.items.count > 1
        case #selector(togglePictureInPicture(_:)):
            let active = hasPictureInPicture && pictureInPicture.isActive
            menuItem.title = active ? "Exit Picture in Picture" : "Picture in Picture"
            return active || (engine.hasMedia && engine.hasPicture)
        case #selector(toggleChannelPanel(_:)):
            menuItem.title = isChannelPanelVisible ? "Hide Live TV" : "Live TV"
            return miniPlayerRestoreFrame == nil
        case #selector(channelUp(_:)), #selector(channelDown(_:)), #selector(toggleCurrentFavourite(_:)), #selector(showChannelInfo(_:)):
            if menuItem.action == #selector(toggleCurrentFavourite(_:)), let channel = liveTV.current {
                menuItem.title = ChannelStore.shared.isFavourite(channel) ? "Remove Channel from Favourites" : "Add Channel to Favourites"
            }
            return isWatchingChannel
        case #selector(previousChannel(_:)):
            return isWatchingChannel && liveTV.previous != nil
        case #selector(toggleVolumeBoost(_:)):
            menuItem.state = settings.volumeBoost ? .on : .off
            return true
        case #selector(toggleShuffle(_:)):
            menuItem.state = settings.shuffle ? .on : .off
            return true
        case #selector(toggleMute(_:)):
            menuItem.title = engine.isMuted ? "Unmute" : "Mute"
            return engine.hasMedia
        case #selector(toggleFullscreen(_:)):
            menuItem.title = view.window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return true
        case #selector(togglePlaylist(_:)):
            menuItem.title = isPlaylistVisible ? "Hide Playlist" : "Show Playlist"
            return true
        case #selector(jumpForward(_:)), #selector(jumpBackward(_:)), #selector(jumpForwardLong(_:)),
            #selector(jumpBackwardLong(_:)), #selector(nextFrame(_:)), #selector(previousFrame(_:)),
            #selector(speedUp(_:)), #selector(slowDown(_:)), #selector(normalSpeed(_:)),
            #selector(addBookmarkAction(_:)), #selector(volumeUp(_:)), #selector(volumeDown(_:)),
            #selector(addSubtitleFile(_:)), #selector(subtitleEarlier(_:)), #selector(subtitleLater(_:)),
            #selector(resetSubtitleDelay(_:)), #selector(rotateVideo(_:)), #selector(audioEarlier(_:)),
            #selector(audioLater(_:)), #selector(resetAudioDelay(_:)), #selector(goToTime(_:)),
            #selector(showMediaInfo(_:)):
            return engine.hasMedia
        case #selector(halfSize(_:)), #selector(actualSize(_:)), #selector(doubleSize(_:)), #selector(fitToScreen(_:)):
            return engine.hasPicture && engine.videoSize.width > 0 && miniPlayerRestoreFrame == nil
                && view.window?.styleMask.contains(.fullScreen) == false
            return engine.hasMedia
        default:
            return true
        }
    }
}

@MainActor
final class TitleOverlayView: NSView {
    private let gradient = CAGradientLayer()
    private let label = HUD.label(size: 13, weight: .semibold)

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.colors = [NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 90),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -90)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
