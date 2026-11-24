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
    private let controls = ControlsOverlay(frame: .zero)
    private let titleBar = TitleOverlayView(frame: .zero)
    private let emptyState = EmptyStateView(frame: .zero)
    let osd = OSDView(frame: .zero)
    private let thumbnail = ThumbnailPreviewView(frame: .zero)
    private let spinner = NSProgressIndicator()
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

    func tearDown() {
        NowPlayingService.shared.playerDidClose(self)
        hideTimer?.invalidate()
        saveProgress(force: true)
        videoView.tearDown()
        engine.shutdown()
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private func installViews() {
        for subview in [videoView, emptyState, titleBar, spinner, osd, sidebar, controls, thumbnail] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(subview)
        }
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        sidebar.isHidden = true
        sidebar.delegate = self

        let maxWidth = controls.widthAnchor.constraint(lessThanOrEqualToConstant: 780)
        let preferredWidth = controls.widthAnchor.constraint(equalToConstant: 780)
        preferredWidth.priority = NSLayoutConstraint.Priority(rawValue: 400)
        controlsTrailing = controls.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -18)
        let centered = controls.centerXAnchor.constraint(equalTo: rootView.centerXAnchor)
        centered.priority = NSLayoutConstraint.Priority(rawValue: 450)
        thumbnailX = thumbnail.centerXAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: rootView.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

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
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -10),
            sidebar.widthAnchor.constraint(equalToConstant: 290),

            thumbnail.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -6),
            thumbnailX
        ])

        controls.onAction = { [weak self] action in self?.handle(action) }
        controls.menuProvider = { [weak self] kind in self?.menu(for: kind) ?? NSMenu() }
        emptyState.onOpenFile = { [weak self] in self?.chooseFiles() }
        emptyState.onOpenURL = { [weak self] in self?.windowController?.promptForURL() }
        emptyState.onOpenRecent = { [weak self] url in self?.windowController?.open([url]) }
    }

    private func installBindings() {
        engine.$currentTime
            .combineLatest(engine.$duration)
            .sink { [weak self] time, duration in
                guard let self else { return }
                self.controls.update(time: time, duration: duration)
                self.saveProgress(force: false)
                NowPlayingService.shared.playerDidUpdateTime(self)
            }
            .store(in: &cancellables)

        engine.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                self.controls.update(isPlaying: isPlaying)
                if isPlaying {
                    NowPlayingService.shared.playerDidStartPlaying(self)
                } else {
                    NowPlayingService.shared.playerDidChange(self)
                }
                if isPlaying {
                    self.scheduleHide()
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
                self.refreshEmptyState()
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .combineLatest(engine.$subtitleTracks)
            .sink { [weak self] _, _ in self?.refreshControlState() }
            .store(in: &cancellables)

        engine.$videoSize
            .removeDuplicates()
            .sink { [weak self] size in self?.fitWindow(to: size) }
            .store(in: &cancellables)

        playlist.$items
            .sink { [weak self] _ in
                self?.sidebar.reload()
                self?.refreshControlState()
            }
            .store(in: &cancellables)

        library.$records
            .sink { [weak self] _ in self?.refreshEmptyState() }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)

        engine.onLoad = { [weak self] item in
            guard let self else { return }
            self.lastSavedTime = 0
            self.watchedMarked = false
            self.resizedForCurrentFile = false
            self.emptyState.setError(nil)
            self.titleBar.title = item.title
            self.view.window?.title = item.title
            self.sidebar.reload()
        }
        engine.onFileLoaded = { [weak self] item in
            guard let self else { return }
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
            self.refreshEmptyState()
            self.osd.show("Can't play this file", symbol: "exclamationmark.triangle.fill", duration: 2.5)
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
                guard let track = note.object as? SubtitleTrack, let url = track.url else { return }
                self?.engine.addSubtitle(url)
                self?.osd.show("Subtitle added: \(track.title)", symbol: "captions.bubble.fill")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.view.window else { return }
                self.windowVisibilityChanged(visible: window.occlusionState.contains(.visible))
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
            .sink { [weak self] _ in self?.refreshControlState() }
            .store(in: &cancellables)
    }

    private func applySettings() {
        if abs(engine.volume - settings.volume) > 0.005 {
            engine.setVolume(settings.volume)
        }
        engine.setGravity(settings.videoGravity)
        engine.setVideoAdjustments(brightness: settings.brightness, contrast: settings.contrast, saturation: settings.saturation)
        engine.setSubtitleScale(settings.subtitleSize / 24)
        engine.setSubtitleDelay(settings.subtitleDelay)
        engine.setHardwareDecoding(settings.hardwareDecoding)
        engine.setEqualizer(settings.equalizerGains)
        playlist.shuffle = settings.shuffle
        playlist.repeatMode = settings.repeatMode
    }

    func applyInitialVolume() {
        engine.setVolume(settings.volume)
    }

    // MARK: - State

    private func refreshEmptyState() {
        let showEmpty = !engine.hasMedia
        emptyState.isHidden = !showEmpty
        if showEmpty {
            emptyState.setRecent(library.continueWatching(limit: 4).filter { $0.url.isFileURL })
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
            hasTracks: !engine.audioTracks.isEmpty || !engine.subtitleTracks.isEmpty,
            isFullscreen: isFullscreen
        )
    }

    private func fitWindow(to size: CGSize) {
        guard size.width > 0, size.height > 0, !resizedForCurrentFile,
            let window = view.window, !window.styleMask.contains(.fullScreen),
            miniPlayerRestoreFrame == nil,
            let screen = window.screen ?? NSScreen.main
        else { return }
        resizedForCurrentFile = true
        let rotated = engine.rotation % 180 != 0
        let videoSize = rotated ? CGSize(width: size.height, height: size.width) : size
        let visible = screen.visibleFrame
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let scale = min(1, maxSize.width / videoSize.width, maxSize.height / videoSize.height)
        var content = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        content.width = max(content.width, 640)
        content.height = max(content.width * videoSize.height / videoSize.width, 360)
        let oldFrame = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: oldFrame.midX - frame.width / 2, y: oldFrame.midY - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    private func saveProgress(force: Bool) {
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
        library.update(url: item.url, title: item.title, resumeTime: time, duration: engine.duration)
    }

    private func handleFinish() {
        guard let item = engine.currentItem else { return }
        if !watchedMarked {
            watchedMarked = true
            library.markWatched(url: item.url, title: item.title, duration: engine.duration)
        }
        if settings.autoplayNext {
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
        suspendVideoWork?.cancel()
        suspendVideoWork = nil
        if visible {
            engine.resumeVideo()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.view.window?.occlusionState.contains(.visible) == false else { return }
            self.engine.suspendVideo()
        }
        suspendVideoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenSuspendDelay, execute: work)
    }

    // MARK: - Chrome visibility

    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        let showControls = visible && engine.hasMedia
        chromeVisible = visible
        let duration = animated ? HUD.fadeDuration : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            controls.animator().alphaValue = showControls ? 1 : 0
            titleBar.animator().alphaValue = showControls ? 1 : 0
            if let buttons = view.window?.standardWindowButton(.closeButton)?.superview {
                buttons.animator().alphaValue = visible ? 1 : 0
            }
        }
        controls.isHidden = !engine.hasMedia
        if !visible {
            thumbnail.hide()
            if engine.hasMedia, rootView.window?.isKeyWindow == true {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        if !chromeVisible || (engine.hasMedia && controls.alphaValue < 1) {
            setChromeVisible(true, animated: true)
        }
        guard engine.isPlaying else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.engine.isPlaying else { return }
                if self.controls.isInteracting || !self.sidebar.isHidden {
                    self.scheduleHide()
                    return
                }
                self.setChromeVisible(false, animated: true)
            }
        }
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
        case .tracks: return tracksMenu()
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

    private func tracksMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addHeader("Audio")
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
        let delay = NSMenuItem(title: "Subtitle Delay: \(String(format: "%+.1f", settings.subtitleDelay)) s", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        delayMenu.addItem(ClosureMenuItem("Earlier by 0.1 s", key: "") { [weak self] in self?.adjustSubtitleDelay(-0.1) })
        delayMenu.addItem(ClosureMenuItem("Later by 0.1 s") { [weak self] in self?.adjustSubtitleDelay(0.1) })
        delayMenu.addItem(ClosureMenuItem("Earlier by 1 s") { [weak self] in self?.adjustSubtitleDelay(-1) })
        delayMenu.addItem(ClosureMenuItem("Later by 1 s") { [weak self] in self?.adjustSubtitleDelay(1) })
        delayMenu.addItem(.separator())
        delayMenu.addItem(ClosureMenuItem("Reset") { [weak self] in self?.adjustSubtitleDelay(nil) })
        delay.submenu = delayMenu
        menu.addItem(delay)
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Take Screenshot") { [weak self] in self?.takeScreenshot(nil) })
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
        let tracks = NSMenuItem(title: "Audio & Subtitles", action: nil, keyEquivalent: "")
        tracks.submenu = tracksMenu()
        menu.addItem(tracks)
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

    func adjustSubtitleDelay(_ delta: TimeInterval?) {
        settings.subtitleDelay = delta.map { ((settings.subtitleDelay + $0) * 10).rounded() / 10 } ?? 0
        osd.show(String(format: "Subtitle delay %+.1f s", settings.subtitleDelay), symbol: "captions.bubble")
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
            osd.show("Drop to add to playlist", symbol: "plus.rectangle.on.rectangle", duration: 1)
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

    @objc func toggleMiniPlayer(_ sender: Any?) {
        guard let window = view.window else { return }
        if let restore = miniPlayerRestoreFrame {
            miniPlayerRestoreFrame = nil
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.setFrame(restore, display: true, animate: true)
            return
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        miniPlayerRestoreFrame = window.frame
        let size = engine.videoSize
        let aspect = size.height > 0 ? size.width / size.height : 16 / 9
        let width: CGFloat = 420
        let content = NSRect(x: 0, y: 0, width: width, height: width / aspect)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.minY + 20)
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.setFrame(frame, display: true, animate: true)
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
            #selector(resetSubtitleDelay(_:)), #selector(rotateVideo(_:)):
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
