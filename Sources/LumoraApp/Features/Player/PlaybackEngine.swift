import AppKit
import Combine
import CMPV

@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var hasMedia = false
    @Published private(set) var volume: Float = 1
    @Published private(set) var isMuted = false
    @Published private(set) var rate: Float = 1
    @Published private(set) var statusMessage = ""
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var videoTracks: [MediaTrack] = []
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var loopA: TimeInterval?
    @Published private(set) var loopB: TimeInterval?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var rotation = 0

    var selectedAudioTrackID: Int? { audioTracks.first { $0.isSelected }?.id }
    var selectedSubtitleTrackID: Int? { subtitleTracks.first { $0.isSelected }?.id }

    private(set) var currentItem: PlaybackItem?
    var onLoad: ((PlaybackItem) -> Void)?
    var onFileLoaded: ((PlaybackItem) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var onScreenshot: ((URL?) -> Void)?

    nonisolated(unsafe) let handle: OpaquePointer
    private let wakeupBox: WeakBox<PlaybackEngine>
    private var isShutDown = false
    private var isPaused = false
    private var isRenderReady = false
    private(set) var renderer: VideoRenderer
    private var voConfigured = false
    private var pendingOpenGLSwitch = false
    var onRendererFailure: (() -> Void)?
    private var pendingLoad: [String]?
    private var isAtEnd = false
    private var nextReplyID: UInt64 = 100
    private var pendingScreenshots: [UInt64: URL] = [:]

    private static var mpvLogging: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUMORA_MPV_LOG"] != nil
        #else
        return false
        #endif
    }

    init(ytdlPath: String, hardwareDecoding: Bool, renderer: VideoRenderer) {
        self.renderer = renderer
        if renderer == .metal {
            Self.configureVulkanDriver()
        }
        guard let created = mpv_create() else {
            fatalError("libmpv could not be initialised")
        }
        handle = created
        wakeupBox = WeakBox<PlaybackEngine>()

        let options: [(String, String)] = [
            ("config", "no"),
            ("terminal", Self.mpvLogging ? "yes" : "no"),
            ("msg-level", "all=warn"),
            ("hwdec", hardwareDecoding ? "auto-safe" : "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("sub-auto", "fuzzy"),
            ("sub-file-paths", "Subtitles:subtitles:Subs:subs"),
            ("sub-codepage", "auto"),
            ("audio-file-auto", "no"),
            ("screenshot-format", "png"),
            ("screenshot-directory", AppPaths.screenshots.path),
            ("ytdl", "yes"),
            ("ytdl-format", "bestvideo[height<=?2160]+bestaudio/best"),
            ("script-opts", "ytdl_hook-ytdl_path=\(Self.safeToolPath(ytdlPath, fallback: "yt-dlp"))"),
            ("load-scripts", "no"),
            ("cache", "auto"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("volume-max", "100"),
            ("audio-client-name", "Lumora"),
            ("hr-seek-framedrop", "yes"),
            ("interpolation", "no")
        ]
        let videoOptions: [(String, String)]
        switch renderer {
        case .metal:
            videoOptions = [
                ("vo", "gpu-next"),
                ("gpu-api", "vulkan"),
                ("gpu-context", "macvk"),
                ("target-colorspace-hint", "auto"),
                ("cursor-autohide", "no"),
                ("force-window", "no")
            ]
        case .openGL:
            videoOptions = [("vo", "libmpv")]
        }
        for (name, value) in options + videoOptions {
            MPV.setOption(handle, name, value)
        }
        let status = mpv_initialize(handle)
        if status < 0 {
            fatalError("libmpv failed to start: \(MPV.errorString(status))")
        }

        wakeupBox.object = self
        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("volume", MPV_FORMAT_DOUBLE)
        observe("mute", MPV_FORMAT_FLAG)
        observe("speed", MPV_FORMAT_DOUBLE)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("paused-for-cache", MPV_FORMAT_FLAG)
        observe("track-list", MPV_FORMAT_NODE)
        observe("chapter-list", MPV_FORMAT_NODE)
        observe("ab-loop-a", MPV_FORMAT_DOUBLE)
        observe("ab-loop-b", MPV_FORMAT_DOUBLE)
        observe("dwidth", MPV_FORMAT_INT64)
        observe("dheight", MPV_FORMAT_INT64)
        observe("video-rotate", MPV_FORMAT_INT64)
        observe("vo-configured", MPV_FORMAT_FLAG)

        let context = Unmanaged.passRetained(wakeupBox).toOpaque()
        mpv_set_wakeup_callback(handle, mpvWakeup, context)
    }

    isolated deinit {
        shutdown()
    }

    var isActive: Bool { !isShutDown }

    /// Every libmpv call goes through these so nothing touches the handle after shutdown().
    private func setProperty(_ name: String, _ value: String) {
        guard !isShutDown else { return }
        MPV.setProperty(handle, name, value)
    }

    private func command(_ args: [String], replyID: UInt64 = 0) {
        guard !isShutDown else { return }
        MPV.command(handle, args, replyID: replyID)
    }

    /// Number of engines still tearing down in the background; the app waits for zero before quitting.
    static private(set) var pendingShutdowns = 0

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        Self.pendingShutdowns += 1
        mpv_set_wakeup_callback(handle, nil, nil)
        let address = UInt(bitPattern: handle)
        let box = Unmanaged.passUnretained(wakeupBox)
        let release = UInt(bitPattern: box.toOpaque())
        // Tearing down the Metal output hops to the main thread, so never block it here.
        DispatchQueue.global(qos: .userInitiated).async {
            if let handle = OpaquePointer(bitPattern: address) {
                mpv_terminate_destroy(handle)
            }
            if let pointer = UnsafeRawPointer(bitPattern: release) {
                Unmanaged<WeakBox<PlaybackEngine>>.fromOpaque(pointer).release()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PlaybackEngine.pendingShutdowns -= 1
                    if PlaybackEngine.pendingShutdowns == 0 {
                        NotificationCenter.default.post(name: .lumoraEnginesStopped, object: nil)
                    }
                }
            }
        }
    }

    /// Metal: hand mpv the view it should render into. Must happen before the first file loads.
    func attachVideoHost(_ view: NSView) {
        guard renderer == .metal else { return }
        let address = Int(bitPattern: Unmanaged.passUnretained(view).toOpaque())
        setProperty("wid", String(address))
        renderContextReady()
    }

    /// Called after the OpenGL layer created its render context following a Metal failure.
    func completeOpenGLFallback() {
        guard pendingOpenGLSwitch else { return }
        pendingOpenGLSwitch = false
        renderer = .openGL
        setProperty("vo", "libmpv")
        // vid is still "auto" after the failed output, so name the track explicitly to restart video.
        if let track = videoTracks.first {
            setProperty("vid", String(track.id))
        }
    }

    func beginOpenGLFallback() {
        guard renderer == .metal, !pendingOpenGLSwitch else { return }
        pendingOpenGLSwitch = true
    }

    private static func configureVulkanDriver() {
        guard getenv("VK_DRIVER_FILES") == nil, getenv("VK_ICD_FILENAMES") == nil else { return }
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json").path)
        }
        #if DEBUG
        candidates.append("/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json")
        #endif
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            setenv("VK_DRIVER_FILES", path, 1)
        }
    }

    func load(_ item: PlaybackItem, resumeTime: TimeInterval = 0) {
        guard !isShutDown else { return }
        currentItem = item
        currentTime = resumeTime
        duration = 0
        audioTracks = []
        subtitleTracks = []
        videoTracks = []
        chapters = []
        isAtEnd = false
        hasMedia = true
        statusMessage = "Opening \(item.title)…"
        let target = item.url.isFileURL ? item.url.path : item.url.absoluteString
        var args = ["loadfile", target, "replace", "-1"]
        if resumeTime > 1 {
            args.append("start=\(resumeTime)")
        }
        if isRenderReady {
            command(args)
        } else {
            pendingLoad = args
        }
        setProperty("pause", "no")
        onLoad?(item)
    }

    func renderContextReady() {
        guard !isRenderReady else { return }
        isRenderReady = true
        if let pendingLoad {
            self.pendingLoad = nil
            command(pendingLoad)
        }
    }

    func play() {
        guard hasMedia else { return }
        if isAtEnd {
            seek(to: 0)
        }
        setProperty("pause", "no")
    }

    func pause() {
        setProperty("pause", "yes")
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func stop() {
        command(["stop"])
        currentItem = nil
        hasMedia = false
        isPlaying = false
        currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        videoTracks = []
        chapters = []
        statusMessage = ""
    }

    func seek(to time: TimeInterval, exact: Bool = true) {
        guard hasMedia else { return }
        let bounded = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        currentTime = bounded
        isAtEnd = false
        command(["seek", String(bounded), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func skip(_ seconds: TimeInterval) {
        guard hasMedia else { return }
        command(["seek", String(seconds), "relative+exact"])
    }

    func setVolume(_ newValue: Float) {
        let bounded = min(max(newValue, 0), 1)
        volume = bounded
        setProperty("volume", String(Double(bounded) * 100))
        if bounded > 0, isMuted {
            setProperty("mute", "no")
        }
    }

    func toggleMute() {
        setProperty("mute", isMuted ? "no" : "yes")
    }

    func setRate(_ newValue: Float) {
        let bounded = min(max(newValue, 0.1), 8)
        rate = bounded
        setProperty("speed", String(Double(bounded)))
    }

    func stepFrame(forward: Bool) {
        guard hasMedia else { return }
        command([forward ? "frame-step" : "frame-back-step"])
    }

    func cycleABLoop() {
        guard hasMedia else { return }
        command(["ab-loop"])
    }

    func clearLoop() {
        setProperty("ab-loop-a", "no")
        setProperty("ab-loop-b", "no")
    }

    func selectAudioTrack(_ id: Int?) {
        setProperty("aid", id.map(String.init) ?? "no")
    }

    func selectSubtitleTrack(_ id: Int?) {
        setProperty("sid", id.map(String.init) ?? "no")
    }

    func addSubtitle(_ url: URL) {
        command(["sub-add", url.path, "select"])
    }

    func setSubtitleDelay(_ seconds: TimeInterval) {
        setProperty("sub-delay", String(seconds))
    }

    func setAudioDelay(_ seconds: TimeInterval) {
        setProperty("audio-delay", String(seconds))
    }

    func setSubtitleScale(_ scale: Double) {
        setProperty("sub-scale", String(min(max(scale, 0.3), 3)))
    }

    func setHardwareDecoding(_ enabled: Bool) {
        setProperty("hwdec", enabled ? "auto-safe" : "no")
    }

    func setVideoAdjustments(brightness: Double, contrast: Double, saturation: Double) {
        setProperty("brightness", String(Int((brightness * 100).rounded())))
        setProperty("contrast", String(Int(((contrast - 1) * 100).rounded())))
        setProperty("saturation", String(Int(((saturation - 1) * 100).rounded())))
    }

    func setGravity(_ preference: VideoGravityPreference) {
        switch preference {
        case .aspect:
            setProperty("keepaspect", "yes")
            setProperty("panscan", "0")
        case .fill:
            setProperty("keepaspect", "yes")
            setProperty("panscan", "1")
        case .stretch:
            setProperty("keepaspect", "no")
            setProperty("panscan", "0")
        }
    }

    func rotate() {
        setProperty("video-rotate", String((rotation + 90) % 360))
    }

    func setEqualizer(_ gains: [Double]) {
        let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let active = zip(frequencies, gains).filter { abs($0.1) >= 0.1 }
        guard !active.isEmpty else {
            setProperty("af", "")
            return
        }
        let chain = active
            .map { "equalizer=f=\($0.0):t=o:w=1:g=\(String(format: "%.1f", $0.1))" }
            .joined(separator: ",")
        setProperty("af", "lavfi=[\(chain)]")
    }

    func screenshot(includeSubtitles: Bool = true) {
        guard hasMedia else { return }
        AppPaths.ensureDirectories()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let title = Self.safeFilename(currentItem?.title ?? "Lumora")
        let url = AppPaths.screenshots.appendingPathComponent("\(title) \(formatter.string(from: Date())).png")
        nextReplyID += 1
        pendingScreenshots[nextReplyID] = url
        command(["screenshot-to-file", url.path, includeSubtitles ? "subtitles" : "video"],
            replyID: nextReplyID
        )
    }

    private static func safeToolPath(_ path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.contains(","), !trimmed.contains("="),
              FileManager.default.isExecutableFile(atPath: trimmed) else { return fallback }
        return trimmed
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "Lumora" : trimmed
    }

    private func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(handle, 0, name, format)
    }

    fileprivate func drainEvents() {
        guard !isShutDown else { return }
        while true {
            guard let pointer = mpv_wait_event(handle, 0) else { return }
            let event = pointer.pointee
            if event.event_id == MPV_EVENT_NONE { return }
            handle(event: event)
            if event.event_id == MPV_EVENT_SHUTDOWN { return }
        }
    }

    private func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            handle(property: property)
        case MPV_EVENT_FILE_LOADED:
            scheduleRendererCheck()
            statusMessage = ""
            isAtEnd = false
            isPlaying = hasMedia && !isPaused
            if let currentItem {
                onFileLoaded?(currentItem)
            }
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if endFile.reason == MPV_END_FILE_REASON_ERROR {
                let message = MPV.errorString(endFile.error)
                hasMedia = false
                isPlaying = false
                statusMessage = "Can't play this file: \(message)"
                onError?(statusMessage)
            }
        case MPV_EVENT_COMMAND_REPLY:
            guard let url = pendingScreenshots.removeValue(forKey: event.reply_userdata) else { return }
            onScreenshot?(event.error >= 0 ? url : nil)
        default:
            break
        }
    }

    private func handle(property: mpv_event_property) {
        let name = String(cString: property.name)
        let hasValue = property.format != MPV_FORMAT_NONE && property.data != nil
        switch name {
        case "time-pos":
            guard hasValue else { return }
            let value = property.data.assumingMemoryBound(to: Double.self).pointee
            if abs(value - currentTime) >= 0.1 || value < currentTime {
                currentTime = value
            }
        case "duration":
            duration = hasValue ? property.data.assumingMemoryBound(to: Double.self).pointee : 0
        case "pause":
            isPaused = hasValue ? property.data.assumingMemoryBound(to: Int32.self).pointee != 0 : true
            isPlaying = hasMedia && !isPaused
        case "volume":
            guard hasValue else { return }
            volume = Float(property.data.assumingMemoryBound(to: Double.self).pointee / 100)
        case "mute":
            isMuted = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
        case "speed":
            guard hasValue else { return }
            rate = Float(property.data.assumingMemoryBound(to: Double.self).pointee)
        case "eof-reached":
            let reached = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
            if reached, !isAtEnd, hasMedia {
                isAtEnd = true
                currentTime = duration
                onFinish?()
            }
        case "paused-for-cache":
            isBuffering = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
        case "track-list":
            guard hasValue else { return }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            parseTracks(MPV.value(from: node) as? [Any] ?? [])
        case "chapter-list":
            guard hasValue else {
                chapters = []
                return
            }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            let list = MPV.value(from: node) as? [Any] ?? []
            chapters = list.compactMap { entry in
                guard let map = entry as? [String: Any], let time = map.double("time") else { return nil }
                return Chapter(title: map.string("title") ?? "", time: time)
            }
        case "ab-loop-a":
            loopA = hasValue ? property.data.assumingMemoryBound(to: Double.self).pointee : nil
        case "ab-loop-b":
            loopB = hasValue ? property.data.assumingMemoryBound(to: Double.self).pointee : nil
        case "dwidth":
            let width = hasValue ? property.data.assumingMemoryBound(to: Int64.self).pointee : 0
            videoSize.width = CGFloat(width)
        case "dheight":
            let height = hasValue ? property.data.assumingMemoryBound(to: Int64.self).pointee : 0
            videoSize.height = CGFloat(height)
        case "vo-configured":
            voConfigured = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
        case "video-rotate":
            rotation = hasValue ? Int(property.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        default:
            break
        }
    }

    private func scheduleRendererCheck() {
        guard renderer == .metal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.renderer == .metal, self.hasMedia, !self.isShutDown else { return }
            // A failed video output makes mpv deselect the video track, so check for any video track.
            if !self.videoTracks.isEmpty, !self.voConfigured {
                self.onRendererFailure?()
            }
        }
    }

    private func parseTracks(_ list: [Any]) {
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        var video: [MediaTrack] = []
        for entry in list {
            guard let map = entry as? [String: Any],
                  let id = map.int("id"),
                  let type = map.string("type"),
                  let kind = TrackKind(rawValue: type) else { continue }
            let track = MediaTrack(
                id: id,
                kind: kind,
                title: map.string("title"),
                language: map.string("lang"),
                codec: map.string("codec"),
                isExternal: map.bool("external"),
                isSelected: map.bool("selected"),
                channels: map.string("demux-channels").flatMap { $0.hasPrefix("unknown") ? nil : $0 }
            )
            switch kind {
            case .audio: audio.append(track)
            case .subtitle: subtitles.append(track)
            case .video: video.append(track)
            }
        }
        audioTracks = audio
        subtitleTracks = subtitles
        videoTracks = video
    }
}

private func mpvWakeup(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<WeakBox<PlaybackEngine>>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            box.object?.drainEvents()
        }
    }
}
