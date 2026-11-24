import AppKit
import AVFoundation
import AVKit
import Combine

@MainActor
final class PlayerViewController: NSViewController, PlayerRootViewDelegate, PlaylistSidebarDelegate {
    private let engine: PlaybackEngine
    private let playlist: PlaylistStore
    private let settings: SettingsStore
    private let library: LibraryStore

    private let rootView = PlayerRootView(frame: .zero)
    private let videoView = VideoView(frame: .zero)
    private let subtitleView = SubtitleOverlayView(frame: .zero)
    private let controls = ControlsOverlay(frame: NSRect(x: 0, y: 0, width: 900, height: 84))
    private lazy var sidebar = PlaylistSidebar(store: playlist)
    private lazy var pictureInPictureView: AVPlayerView = {
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.player = engine.player
        view.controlsStyle = .none
        view.alphaValue = 0.01
        return view
    }()

    private var cancellables = Set<AnyCancellable>()
    private var controlsHideTimer: Timer?
    private var externalSubtitleTracks: [SubtitleTrack] = []
    private var cuesByTrackID: [String: [SubtitleCue]] = [:]
    private var selectedSubtitleID: String?
    private var thumbnailRequestToken = 0
    private var lastSavedTime: TimeInterval = 0
    private var subtitleObserver: NSObjectProtocol?
    private var externalPlaybackEnabled = true

    init(
        engine: PlaybackEngine,
        playlist: PlaylistStore,
        settings: SettingsStore,
        library: LibraryStore
    ) {
        self.engine = engine
        self.playlist = playlist
        self.settings = settings
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let subtitleObserver {
            NotificationCenter.default.removeObserver(subtitleObserver)
        }
    }

    override func loadView() {
        view = rootView
        rootView.eventDelegate = self
        rootView.registerForDraggedTypes([.fileURL, .URL])
        installViews()
        installBindings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(rootView)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        controlsHideTimer?.invalidate()
    }

    private func installViews() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        subtitleView.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        pictureInPictureView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(videoView)
        rootView.addSubview(subtitleView)
        rootView.addSubview(controls)
        rootView.addSubview(sidebar)
        rootView.addSubview(pictureInPictureView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: rootView.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            subtitleView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            subtitleView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            subtitleView.topAnchor.constraint(equalTo: rootView.topAnchor),
            subtitleView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),

            controls.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),

            sidebar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            sidebar.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -12),
            sidebar.widthAnchor.constraint(equalToConstant: 280),

            pictureInPictureView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            pictureInPictureView.topAnchor.constraint(equalTo: rootView.topAnchor),
            pictureInPictureView.widthAnchor.constraint(equalToConstant: 1),
            pictureInPictureView.heightAnchor.constraint(equalToConstant: 1)
        ])

        sidebar.isHidden = true
        sidebar.delegate = self
        videoView.player = engine.player
        controls.onAction = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
    }

    private func installBindings() {
        playlist.shuffle = settings.shuffle
        playlist.repeatMode = settings.repeatMode

        engine.$currentTime
            .combineLatest(engine.$duration)
            .sink { [weak self] time, duration in
                guard let self else { return }
                self.controls.update(time: time, duration: duration, isPlaying: self.engine.isPlaying, volume: self.engine.volume)
                self.updateSubtitle(at: time)
                self.saveProgress(time: time, duration: duration)
            }
            .store(in: &cancellables)

        engine.$isPlaying
            .sink { [weak self] isPlaying in
                guard let self else { return }
                self.controls.update(
                    time: self.engine.currentTime,
                    duration: self.engine.duration,
                    isPlaying: isPlaying,
                    volume: self.engine.volume
                )
                if isPlaying {
                    self.scheduleControlsHide()
                } else {
                    self.controls.isHidden = false
                    self.controlsHideTimer?.invalidate()
                }
            }
            .store(in: &cancellables)

        engine.$volume
            .sink { [weak self] volume in
                guard let self else { return }
                self.controls.update(
                    time: self.engine.currentTime,
                    duration: self.engine.duration,
                    isPlaying: self.engine.isPlaying,
                    volume: volume
                )
            }
            .store(in: &cancellables)

        engine.$audioTracks
            .sink { [weak self] _ in
                self?.refreshTrackMenus()
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .sink { [weak self] _ in
                self?.refreshTrackMenus()
            }
            .store(in: &cancellables)

        engine.$selectedAudioTrackID
            .sink { [weak self] _ in
                self?.refreshTrackMenus()
            }
            .store(in: &cancellables)

        playlist.$items
            .sink { [weak self] _ in
                self?.sidebar.reload()
            }
            .store(in: &cancellables)

        settings.$brightness
            .sink { [weak self] value in
                self?.videoView.brightness = value
            }
            .store(in: &cancellables)

        settings.$contrast
            .sink { [weak self] value in
                self?.videoView.contrast = value
            }
            .store(in: &cancellables)

        settings.$saturation
            .sink { [weak self] value in
                self?.videoView.saturation = value
            }
            .store(in: &cancellables)

        settings.$subtitleSize
            .sink { [weak self] value in
                self?.subtitleView.fontSize = value
            }
            .store(in: &cancellables)

        settings.$videoGravity
            .sink { [weak self] preference in
                guard let self else { return }
                switch preference {
                case .aspect: self.videoView.gravity = .resizeAspect
                case .fill: self.videoView.gravity = .resizeAspectFill
                case .stretch: self.videoView.gravity = .resize
                }
            }
            .store(in: &cancellables)

        settings.$shuffle
            .sink { [weak self] value in
                self?.playlist.shuffle = value
            }
            .store(in: &cancellables)

        settings.$repeatMode
            .sink { [weak self] value in
                self?.playlist.repeatMode = value
            }
            .store(in: &cancellables)

        engine.onLoad = { [weak self] item in
            Task { @MainActor in
                self?.handleLoad(item)
            }
        }
        engine.onFinish = { [weak self] in
            Task { @MainActor in
                self?.handleFinish()
            }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in
                self?.presentError(message)
            }
        }
        subtitleObserver = NotificationCenter.default.addObserver(
            forName: .lumoraDidDownloadSubtitle,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let track = note.object as? SubtitleTrack else { return }
            Task { @MainActor in
                self?.addDownloadedSubtitle(track)
            }
        }
    }

    private func addDownloadedSubtitle(_ track: SubtitleTrack) {
        guard let url = track.url else { return }
        externalSubtitleTracks.append(track)
        cuesByTrackID[track.id] = SubtitleService.cues(at: url)
        selectedSubtitleID = "external:\(track.id)"
        updateSubtitle(at: engine.currentTime)
        refreshTrackMenus()
    }

    private func handleLoad(_ item: PlaybackItem) {
        lastSavedTime = 0
        loadSubtitles(for: item)
        refreshTrackMenus()
        if item.url.isFileURL {
            ThumbnailService.shared.prewarm(url: item.url, duration: engine.duration)
        }
    }

    private func handleFinish() {
        guard let item = engine.currentItem else { return }
        library.markWatched(url: item.url, title: item.title, duration: engine.duration)
        if settings.autoplayNext {
            (view.window?.windowController as? MainWindowController)?.playNext(auto: true)
        }
    }

    private func saveProgress(time: TimeInterval, duration: TimeInterval) {
        guard let item = engine.currentItem, duration > 0, time > 0 else { return }
        if abs(time - lastSavedTime) >= 5 {
            library.update(url: item.url, title: item.title, resumeTime: time, duration: duration)
            lastSavedTime = time
        }
        if time > duration - 1 {
            library.markWatched(url: item.url, title: item.title, duration: duration)
        }
    }

    private func loadSubtitles(for item: PlaybackItem) {
        externalSubtitleTracks = SubtitleService.sidecarTracks(for: item.url)
        cuesByTrackID.removeAll()
        for track in externalSubtitleTracks {
            guard let url = track.url else { continue }
            cuesByTrackID[track.id] = SubtitleService.cues(at: url)
        }
        if let first = externalSubtitleTracks.first {
            selectedSubtitleID = "external:\(first.id)"
        } else {
            selectedSubtitleID = nil
        }
        updateSubtitle(at: engine.currentTime)
        if settings.autoDownloadSubtitles {
            autoDownloadSubtitles(for: item)
        }
    }

    private func autoDownloadSubtitles(for item: PlaybackItem) {
        guard !settings.openSubtitlesAPIKey.isEmpty else { return }
        Task { @MainActor in
            let results = await OpenSubtitlesService.search(
                query: item.title,
                languages: settings.subtitleLanguages,
                apiKey: settings.openSubtitlesAPIKey
            )
            guard let result = results.first else { return }
            guard let data = await OpenSubtitlesService.download(result: result, apiKey: settings.openSubtitlesAPIKey) else { return }
            guard let track = SubtitleService.saveDownloaded(
                data,
                language: result.language,
                filename: result.title
            ) else { return }
            externalSubtitleTracks.append(track)
            guard let url = track.url else { return }
            cuesByTrackID[track.id] = SubtitleService.cues(at: url)
            selectedSubtitleID = "external:\(track.id)"
            refreshTrackMenus()
        }
    }

    private func updateSubtitle(at time: TimeInterval) {
        guard let selectedSubtitleID,
              selectedSubtitleID.hasPrefix("external:"),
              let cues = cuesByTrackID[String(selectedSubtitleID.dropFirst("external:".count))] else {
            subtitleView.cue = nil
            return
        }
        let adjusted = time + settings.subtitleDelay
        subtitleView.cue = cues.first { adjusted >= $0.start && adjusted <= $0.end }
    }

    private func subtitleChoices() -> [SubtitleChoice] {
        var choices = [SubtitleChoice(title: "Off", id: nil)]
        for track in externalSubtitleTracks {
            choices.append(SubtitleChoice(title: "\(track.title) (\(track.language))", id: "external:\(track.id)"))
        }
        for track in engine.subtitleTracks {
            choices.append(SubtitleChoice(title: "\(track.title) [embedded]", id: "native:\(track.id)"))
        }
        return choices
    }

    private func refreshTrackMenus() {
        let choices = subtitleChoices()
        if let selectedSubtitleID, !choices.contains(where: { $0.id == selectedSubtitleID }) {
            self.selectedSubtitleID = nil
        }
        controls.updateTrackMenus(
            audio: engine.audioTracks,
            selectedAudio: engine.selectedAudioTrackID,
            subtitles: choices,
            selectedSubtitle: selectedSubtitleID
        )
    }

    private func applySubtitleSelection(_ id: String?) {
        selectedSubtitleID = id
        if let id, id.hasPrefix("native:") {
            let raw = String(id.dropFirst("native:".count))
            engine.selectSubtitleTrack(Int32(raw))
        } else {
            engine.selectSubtitleTrack(nil)
        }
        updateSubtitle(at: engine.currentTime)
        refreshTrackMenus()
    }

    private func handle(_ action: ControlsAction) {
        switch action {
        case .togglePlayback:
            engine.togglePlayback()
            scheduleControlsHide()
        case .previous:
            (view.window?.windowController as? MainWindowController)?.playPrevious()
        case .next:
            (view.window?.windowController as? MainWindowController)?.playNext(auto: false)
        case .seekBackward:
            engine.skip(-10)
        case .seekForward:
            engine.skip(10)
        case let .seek(fraction):
            engine.seek(to: fraction * engine.duration)
        case let .hover(fraction):
            guard let fraction else {
                controls.hideThumbnail()
                return
            }
            requestThumbnail(at: fraction)
        case let .volume(value):
            engine.setVolume(value)
        case .toggleMute:
            engine.toggleMute()
        case .toggleFullscreen:
            view.window?.toggleFullScreen(nil)
        case .togglePictureInPicture:
            togglePictureInPicture()
        case .togglePlaylist:
            togglePlaylist()
        case .screenshot:
            takeScreenshot(nil)
        case let .audioTrack(id):
            engine.selectAudioTrack(id)
            refreshTrackMenus()
        case let .subtitleOption(id):
            applySubtitleSelection(id)
        case .toggleAirPlay:
            externalPlaybackEnabled.toggle()
            CastService.shared.configureExternalPlayback(for: engine.player, enabled: externalPlaybackEnabled)
        }
    }

    private func requestThumbnail(at fraction: Double) {
        guard let item = engine.currentItem, engine.duration > 0 else { return }
        let time = fraction * engine.duration
        thumbnailRequestToken += 1
        let token = thumbnailRequestToken
        Task { @MainActor in
            let image = await ThumbnailService.shared.thumbnail(url: item.url, time: time)
            guard self.thumbnailRequestToken == token else { return }
            self.controls.showThumbnail(image: image, time: time)
        }
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controls.isHidden = false
        guard engine.isPlaying else { return }
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.engine.isPlaying {
                    self.controls.isHidden = true
                    self.controls.hideThumbnail()
                }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .video, .data]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                (self?.view.window?.windowController as? MainWindowController)?.open(panel.urls)
            }
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Playback error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func playerRootViewDidMoveMouse(_ view: PlayerRootView) {
        scheduleControlsHide()
    }

    func playerRootViewDidSingleClick(_ view: PlayerRootView) {
        scheduleControlsHide()
    }

    func playerRootViewDidDoubleClick(_ view: PlayerRootView) {
        toggleFullscreen(self)
    }

    func playerRootView(_ view: PlayerRootView, didScrollX x: CGFloat, y: CGFloat, flags: NSEvent.ModifierFlags) {
        if abs(y) > abs(x) {
            engine.setVolume(engine.volume - Float(y / 400))
        } else {
            engine.skip(TimeInterval(x))
        }
        scheduleControlsHide()
    }

    func playerRootView(_ view: PlayerRootView, handleKeyDown event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            return false
        }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        let bigSeek = event.modifierFlags.contains(.option)
        let seekAmount: TimeInterval = bigSeek ? 60 : 10
        switch event.keyCode {
        case 123:
            engine.skip(-seekAmount)
            return true
        case 124:
            engine.skip(seekAmount)
            return true
        case 126:
            engine.setVolume(engine.volume + 0.05)
            return true
        case 125:
            engine.setVolume(engine.volume - 0.05)
            return true
        default:
            break
        }
        switch key {
        case " ":
            engine.togglePlayback()
        case "f":
            toggleFullscreen(self)
        case "p":
            togglePictureInPicture(self)
        case "m":
            engine.toggleMute()
        case "s":
            takeScreenshot(self)
        case "b":
            addBookmark()
        case "l":
            togglePlaylist()
        case "t":
            cycleSubtitles()
        case "r":
            cycleRepeatMode()
        case "c":
            controls.isHidden.toggle()
        case "]":
            (view.window?.windowController as? MainWindowController)?.playNext(auto: false)
        case "[":
            (view.window?.windowController as? MainWindowController)?.playPrevious()
        default:
            return false
        }
        scheduleControlsHide()
        return true
    }

    func playerRootView(_ view: PlayerRootView, didReceiveURLs urls: [URL]) {
        (view.window?.windowController as? MainWindowController)?.open(urls)
    }

    func playlistSidebar(_ sidebar: PlaylistSidebar, didSelect index: Int) {
        playlist.select(at: index)
        (view.window?.windowController as? MainWindowController)?.playCurrent()
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
        playlist.remove(at: index)
        sidebar.reload()
    }

    @objc func togglePlayback(_ sender: Any) {
        engine.togglePlayback()
        scheduleControlsHide()
    }

    @objc func stopPlayback(_ sender: Any) {
        engine.stop()
    }

    @objc func seekBackward(_ sender: Any) {
        engine.skip(-10)
    }

    @objc func seekForward(_ sender: Any) {
        engine.skip(10)
    }

    @objc func nextItem(_ sender: Any) {
        (view.window?.windowController as? MainWindowController)?.playNext(auto: false)
    }

    @objc func previousItem(_ sender: Any) {
        (view.window?.windowController as? MainWindowController)?.playPrevious()
    }

    @objc func toggleFullscreen(_ sender: Any) {
        view.window?.toggleFullScreen(nil)
    }

    @objc func togglePictureInPicture(_ sender: Any) {
        togglePictureInPicture()
    }

    private func togglePictureInPicture() {
        let selector = NSSelectorFromString("togglePictureInPicture:")
        guard pictureInPictureView.responds(to: selector) else {
            presentError("Picture in Picture is not available in this build.")
            return
        }
        pictureInPictureView.perform(selector, with: nil)
    }

    @objc func takeScreenshot(_ sender: Any?) {
        guard let url = engine.screenshot() else {
            presentError("Could not capture a screenshot from the current frame.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func togglePlaylist(_ sender: Any) {
        togglePlaylist()
    }

    @objc func toggleControlsVisibility(_ sender: Any) {
        controls.isHidden.toggle()
    }

    @objc func cycleSubtitles(_ sender: Any) {
        cycleSubtitles()
    }

    @objc func cycleRepeatMode(_ sender: Any) {
        cycleRepeatMode()
    }

    private func togglePlaylist() {
        sidebar.isHidden.toggle()
        if !sidebar.isHidden {
            sidebar.reload()
        }
        scheduleControlsHide()
    }

    private func cycleSubtitles() {
        let choices = subtitleChoices()
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex { $0.id == selectedSubtitleID } ?? 0
        let next = (current + 1) % choices.count
        applySubtitleSelection(choices[next].id)
    }

    private func cycleRepeatMode() {
        let all = RepeatMode.allCases
        let current = all.firstIndex(of: settings.repeatMode) ?? 0
        settings.repeatMode = all[(current + 1) % all.count]
    }

    private func addBookmark() {
        guard let item = engine.currentItem else { return }
        library.addBookmark(
            url: item.url,
            time: engine.currentTime,
            label: TimeFormatter.string(engine.currentTime)
        )
    }
}
