import AppKit
import CMPV
import Combine
import Darwin

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
    /// Renditions of an online video (YouTube formats, HLS variants); empty for local files.
    @Published private(set) var streamVariants: [StreamVariant] = []
    /// Downloaded time ranges of a stream (for the timeline); empty for local files.
    @Published private(set) var bufferedRanges: [ClosedRange<TimeInterval>] = []
    /// A stream with no end (live TV, radio).
    @Published private(set) var isLive = false
    /// Title/artist/album tags of the current file, keys lowercased.
    @Published private(set) var mediaTags: [String: String] = [:]
    /// False once loaded when the file has no picture at all (no video and no cover art).
    @Published private(set) var hasPicture = true
    /// Output devices mpv can play to ("auto" first).
    @Published private(set) var audioDevices: [(name: String, description: String)] = []
    @Published private(set) var audioDevice = "auto"
    @Published private(set) var deinterlace = "no"
    /// Display shape forced by Aspect Ratio or Crop for the current file (width / height).
    @Published private(set) var aspectOverride: Double?
    @Published private(set) var cropAspect: Double?
    /// 1 normally, 2 with volume boost on (mpv's volume 200).
    private(set) var maxVolume: Float = 1
    /// Decoded picture size before crop and aspect changes (crop is computed from this).
    private var sourceSize: CGSize = .zero
    private var isFileLoaded = false
    private var isPartiallySeekable = false
    var isStream: Bool { currentItem.map { !$0.url.isFileURL } ?? false }

    var selectedAudioTrackID: Int? { audioTracks.first { $0.isSelected }?.id }
    var selectedSubtitleTrackID: Int? { subtitleTracks.first { $0.isSelected }?.id }

    private(set) var currentItem: PlaybackItem?
    var onLoad: ((PlaybackItem) -> Void)?
    var onFileLoaded: ((PlaybackItem) -> Void)?
    /// A stream's real title arrived (yt-dlp or stream metadata), replacing its link.
    var onTitleChange: ((PlaybackItem) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var onScreenshot: ((URL?) -> Void)?

    nonisolated(unsafe) let handle: OpaquePointer
    private let wakeupBox: EngineWakeup
    private var isShutDown = false
    private var isPaused = false
    private var isRenderReady = false
    private(set) var renderer: VideoRenderer
    private var voConfigured = false
    private var pendingOpenGLSwitch = false
    private var suspendedVideoID: Int?
    var isVideoSuspended: Bool { suspendedVideoID != nil }
    var onRendererFailure: (() -> Void)?
    private var pendingLoad: [String]?
    private var isAtEnd = false
    private var nextReplyID: UInt64 = 100
    private final class PropertyBatch {
        var values: [String: String] = [:]
        var remaining: Int
        let completion: ([String: String]) -> Void
        init(count: Int, completion: @escaping ([String: String]) -> Void) {
            remaining = count
            self.completion = completion
        }
    }
    private var pendingReads: [UInt64: (name: String, batch: PropertyBatch)] = [:]
    private var pendingScreenshots: [UInt64: URL] = [:]

    private static var mpvLogging: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["LUMORA_MPV_LOG"] != nil
        #else
            return false
        #endif
    }

    /// Height cap used when yt-dlp picks the starting format; nil means best available.
    private(set) var streamHeightCap: Int?
    private var currentEdition = -1

    init(ytdlPath: String, hardwareDecoding: Bool, renderer: VideoRenderer, streamHeightCap: Int? = 1080) {
        self.renderer = renderer
        self.streamHeightCap = streamHeightCap
        if renderer == .metal {
            Self.configureVulkanDriver()
        }
        guard let created = mpv_create() else {
            fatalError("libmpv could not be initialised")
        }
        handle = created
        wakeupBox = EngineWakeup()

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
            ("ytdl-format", StreamQuality.ytdlFormat(maxHeight: streamHeightCap)),
            // Web pages go straight to yt-dlp instead of failing an ffmpeg probe first; direct
            // media links opt out per file in load().
            (
                "script-opts",
                "ytdl_hook-ytdl_path=\(Self.safeToolPath(ytdlPath, fallback: "yt-dlp")),ytdl_hook-try_ytdl_first=yes"
            ),
            // One long HTTP download gets throttled by YouTube and many CDNs (~700 KB/s here);
            // 10 MiB range requests on one kept-alive connection, as yt-dlp does, run at full speed.
            ("stream-lavf-o", "request_size=10485760,multiple_requests=1"),
            ("load-scripts", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-auto-profiles", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),
            ("gpu-shader-cache", "yes"),
            ("gpu-shader-cache-dir", AppPaths.mpvCache.path),
            ("icc-cache-dir", AppPaths.mpvCache.path),
            ("cache", "auto"),
            ("demuxer-max-bytes", "96MiB"),
            ("demuxer-max-back-bytes", "32MiB"),
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
        let testOptions: [(String, String)] = DebugMode.background ? [("force-render", "yes")] : []
        for (name, value) in options + videoOptions + testOptions {
            MPV.setOption(handle, name, value)
        }
        #if DEBUG
            // LUMORA_MPV_OPTS="name=value;name=value" overrides options for experiments.
            if let overrides = ProcessInfo.processInfo.environment["LUMORA_MPV_OPTS"] {
                for pair in overrides.split(separator: ";") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        MPV.setOption(handle, parts[0], parts[1])
                    }
                }
            }
        #endif
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
        observe("edition-list", MPV_FORMAT_NODE)
        observe("demuxer-cache-state", MPV_FORMAT_NODE)
        observe("metadata", MPV_FORMAT_NODE)
        observe("partially-seekable", MPV_FORMAT_FLAG)
        observe("media-title", MPV_FORMAT_STRING)
        observe("width", MPV_FORMAT_INT64)
        observe("height", MPV_FORMAT_INT64)
        observe("audio-device-list", MPV_FORMAT_NODE)
        observe("audio-device", MPV_FORMAT_STRING)
        observe("deinterlace", MPV_FORMAT_STRING)
        observe("current-edition", MPV_FORMAT_INT64)

        mpv_request_log_messages(handle, "error")
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
                Unmanaged<EngineWakeup>.fromOpaque(pointer).release()
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
        streamVariants = []
        bufferedRanges = []
        isLive = false
        mediaTags = [:]
        hasPicture = true
        isFileLoaded = false
        let target = item.url.isFileURL ? item.url.path : item.url.absoluteString
        // mpv reads "proto://…" in any string as a protocol (lavfi, edl, memory, av…). Only an
        // absolute path or an allowed network link may reach loadfile, whatever opened it.
        guard Self.isSafeTarget(target, isFile: item.url.isFileURL) else {
            statusMessage = "Couldn't play “\(item.title)”. This kind of link isn't supported."
            onError?(statusMessage)
            return
        }
        // Local files read ahead from disk on demand. Streams keep a large window both ways so
        // ±10 s jumps land inside data that is already downloaded.
        var fileOptions: [String]
        if item.url.isFileURL {
            statusMessage = "Opening \(item.title)…"
            fileOptions = ["demuxer-max-bytes=32MiB", "demuxer-max-back-bytes=8MiB"]
        } else {
            let isChannel = item.kind == .channel
            let isDirectMedia = isChannel || Self.isDirectMediaURL(item.url)
            statusMessage = isChannel ? "Tuning to \(item.title)…" : isDirectMedia ? "Connecting…" : "Fetching video from \(item.url.host ?? "the web")…"
            fileOptions = [
                "cache=yes", "cache-secs=120", "demuxer-max-bytes=128MiB", "demuxer-max-back-bytes=48MiB",
                "demuxer-seekable-cache=yes"
            ]
            if isDirectMedia {
                fileOptions.append("ytdl=no")
            }
            // Per-stream headers from channel lists. "%n%value" passes the value verbatim, since
            // browser identities contain commas.
            if let agent = item.userAgent, !agent.isEmpty {
                fileOptions.append("user-agent=%\(agent.utf8.count)%\(agent)")
            }
            if let referrer = item.referrer, !referrer.isEmpty {
                fileOptions.append("referrer=%\(referrer.utf8.count)%\(referrer)")
            }
        }
        if resumeTime > 1 {
            fileOptions.append("start=\(resumeTime)")
        }
        let args = ["loadfile", target, "replace", "-1", fileOptions.joined(separator: ",")]
        DebugTimeline.log("load \(item.url.isFileURL ? "file" : "url")")
        resetPerFileState()
        subtitleDelay = defaultSubtitleDelay
        setProperty("sub-delay", String(subtitleDelay))
        audioDelay = 0
        setProperty("audio-delay", "0")
        if isRenderReady {
            command(args)
        } else {
            pendingLoad = args
        }
        setProperty("pause", "no")
        onLoad?(item)
    }

    /// mpv keeps these options across files; reset them so one file's choices don't leak into the
    /// next (e.g. audio track 2 making the next file silent, an A-B loop or rotation carrying over).
    private func resetPerFileState() {
        if suspendedVideoID != nil {
            suspendedVideoID = nil
        }
        setProperty("vid", "auto")
        setProperty("aid", "auto")
        setProperty("sid", "auto")
        setProperty("ab-loop-a", "no")
        setProperty("ab-loop-b", "no")
        setProperty("video-rotate", "0")
        setProperty("edition", "auto")
        setProperty("video-aspect-override", "no")
        setProperty("video-crop", "")
        aspectOverride = nil
        cropAspect = nil
    }

    // MARK: Picture shape

    /// Forces the display aspect ratio (nil = the file's own).
    func setAspectOverride(_ ratio: Double?) {
        aspectOverride = ratio
        setProperty("video-aspect-override", ratio.map { String(format: "%.4f", $0) } ?? "no")
    }

    /// Crops the centre of the picture to an aspect ratio, e.g. to remove black bars (nil = no crop).
    func setCrop(aspect target: Double?) {
        cropAspect = target
        guard let target, sourceSize.width > 0, sourceSize.height > 0 else {
            setProperty("video-crop", "")
            return
        }
        let width = sourceSize.width
        let height = sourceSize.height
        var crop = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > target {
            crop.size.width = (height * target).rounded()
            crop.origin.x = ((width - crop.width) / 2).rounded()
        } else {
            crop.size.height = (width / target).rounded()
            crop.origin.y = ((height - crop.height) / 2).rounded()
        }
        setProperty("video-crop", "\(Int(crop.width))x\(Int(crop.height))+\(Int(crop.minX))+\(Int(crop.minY))")
    }

    /// The shape the picture is shown in after Aspect Ratio and Crop.
    var displayAspect: Double? {
        if let cropAspect { return cropAspect }
        if let aspectOverride { return aspectOverride }
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        return videoSize.width / videoSize.height
    }

    func setDeinterlace(_ mode: String) {
        setProperty("deinterlace", mode)
    }

    // MARK: Audio output

    func setAudioDevice(_ name: String) {
        setProperty("audio-device", name)
    }

    /// Lets the volume go to 200% (software gain; may distort loud sources).
    func setVolumeBoost(_ enabled: Bool) {
        maxVolume = enabled ? 2 : 1
        setProperty("volume-max", enabled ? "200" : "100")
        if volume > maxVolume {
            setVolume(maxVolume)
        }
    }

    // MARK: Subtitle style

    func setSubtitleStyle(font: String, color: String, background: SubtitleBackground, position: Double) {
        setProperty("sub-font", font.isEmpty ? "sans-serif" : font)
        setProperty("sub-color", color)
        switch background {
        case .outline:
            setProperty("sub-border-style", "outline-and-shadow")
            setProperty("sub-outline-color", "#000000")
            setProperty("sub-outline-size", "2.5")
            setProperty("sub-shadow-offset", "0")
        case .shadow:
            setProperty("sub-border-style", "outline-and-shadow")
            setProperty("sub-outline-size", "0")
            setProperty("sub-back-color", "#CC000000")
            setProperty("sub-shadow-offset", "2.5")
        case .box:
            setProperty("sub-border-style", "opaque-box")
            setProperty("sub-outline-color", "#B3000000")
            setProperty("sub-outline-size", "6")
            setProperty("sub-shadow-offset", "0")
        }
        setProperty("sub-pos", String(Int(min(max(position, 0), 100))))
    }

    /// Track languages picked automatically when a file opens ("en,ja"; empty = the file's default).
    func setPreferredLanguages(audio: String, subtitles: String) {
        setProperty("alang", Self.languageList(audio))
        setProperty("slang", Self.languageList(subtitles))
    }

    static func languageList(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() }.joined(separator: ",")
    }

    static func isSafeTarget(_ target: String, isFile: Bool) -> Bool {
        if isFile {
            return target.hasPrefix("/") && !target.contains("://")
        }
        guard let scheme = URL(string: target)?.scheme?.lowercased() else { return false }
        return PlaylistImporter.allowedSchemes.contains(scheme)
    }

    private static let directMediaExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "flv", "ts", "m2ts", "mts", "m3u8", "m3u", "mpd",
        "mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "wmv", "mpg", "mpeg", "3gp"
    ]

    /// A link straight to a media file or playlist needs no yt-dlp lookup.
    static func isDirectMediaURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        return directMediaExtensions.contains(url.pathExtension.lowercased())
    }

    /// Switches the current stream to another rendition in place; playback keeps its position.
    func selectStreamVariant(_ id: Int) {
        guard streamVariants.contains(where: { $0.id == id }) else { return }
        if let variant = streamVariants.first(where: { $0.id == id }), variant.height > 0 {
            streamHeightCap = variant.height
            setProperty("ytdl-format", StreamQuality.ytdlFormat(maxHeight: variant.height))
        }
        setProperty("edition", String(id))
    }

    /// Default quality for online videos opened from now on.
    func setStreamHeightCap(_ height: Int?) {
        streamHeightCap = height
        setProperty("ytdl-format", StreamQuality.ytdlFormat(maxHeight: height))
    }

    func renderContextReady() {
        guard !isRenderReady else { return }
        isRenderReady = true
        if let pendingLoad {
            self.pendingLoad = nil
            command(pendingLoad)
        }
    }

    /// Turns the video output off while nobody can see it (audio keeps playing). mpv then
    /// destroys its renderer and GPU textures; `resumeVideo()` brings video back at the same spot.
    func suspendVideo() {
        // Without an audio track nothing would keep playback going, so leave video-only files alone.
        guard hasMedia, suspendedVideoID == nil, !isSoftwareOutput, !audioTracks.isEmpty,
            let track = videoTracks.first(where: { $0.isSelected })
        else { return }
        suspendedVideoID = track.id
        setProperty("vid", "no")
        Self.releaseFreeMemory(after: 1.5)
    }

    func resumeVideo() {
        guard let id = suspendedVideoID else { return }
        suspendedVideoID = nil
        setProperty("vid", String(id))
    }

    /// Hands freed malloc pages back to the system so the memory figure drops right away.
    nonisolated static func releaseFreeMemory(after delay: TimeInterval = 0) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            malloc_zone_pressure_relief(nil, 0)
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
        if suspendedVideoID != nil {
            setProperty("vid", "auto")
        }
        suspendedVideoID = nil
        Self.releaseFreeMemory(after: 1)
    }

    func seek(to time: TimeInterval, exact: Bool = true) {
        guard hasMedia else { return }
        let bounded = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        currentTime = bounded
        isAtEnd = false
        command(["seek", String(bounded), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    /// Every relative jump (keys, buttons, menus, media keys), for the on-screen skip ripple.
    var onSkip: ((TimeInterval) -> Void)?

    func skip(_ seconds: TimeInterval) {
        guard hasMedia else { return }
        onSkip?(seconds)
        isAtEnd = false
        command(["seek", String(seconds), "relative+exact"])
    }

    func setVolume(_ newValue: Float) {
        let bounded = min(max(newValue, 0), maxVolume)
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
        isAtEnd = false
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

    /// Delay for the current file only; reset to `defaultSubtitleDelay` whenever a file loads.
    private(set) var subtitleDelay: TimeInterval = 0
    var defaultSubtitleDelay: TimeInterval = 0

    func adjustSubtitleDelay(by delta: TimeInterval?) {
        let value = delta.map { ((subtitleDelay + $0) * 10).rounded() / 10 } ?? 0
        subtitleDelay = min(max(value, -10), 10)
        setProperty("sub-delay", String(subtitleDelay))
    }

    func setSubtitleDelay(_ seconds: TimeInterval) {
        setProperty("sub-delay", String(seconds))
    }

    private(set) var audioDelay: TimeInterval = 0

    func adjustAudioDelay(by delta: TimeInterval?) {
        let value = delta.map { ((audioDelay + $0) * 10).rounded() / 10 } ?? 0
        audioDelay = min(max(value, -10), 10)
        setProperty("audio-delay", String(audioDelay))
    }

    func setAudioDelay(_ seconds: TimeInterval) {
        setProperty("audio-delay", String(seconds))
    }

    func setSubtitleScale(_ scale: Double) {
        setProperty("sub-scale", String(min(max(scale, 0.3), 3)))
    }

    private var hardwareDecoding = true
    private(set) var isSoftwareOutput = false

    func setHardwareDecoding(_ enabled: Bool) {
        hardwareDecoding = enabled
        setProperty("hwdec", isSoftwareOutput ? (enabled ? "auto-copy-safe" : "no") : (enabled ? "auto-safe" : "no"))
    }

    /// Picture in Picture: render through the render API (software) instead of the Metal output.
    /// Hardware decoding copies frames back to memory, which the software renderer needs.
    func beginSoftwareOutput() {
        guard renderer == .metal, !isSoftwareOutput else { return }
        isSoftwareOutput = true
        setProperty("hwdec", hardwareDecoding ? "auto-copy-safe" : "no")
        setProperty("vo", "libmpv")
        restartVideoTrack()
    }

    func endSoftwareOutput() {
        guard isSoftwareOutput else { return }
        isSoftwareOutput = false
        setProperty("vo", "gpu-next")
        setProperty("hwdec", hardwareDecoding ? "auto-safe" : "no")
        restartVideoTrack()
    }

    /// Changing the output can leave video deselected; name the track to bring it back.
    private func restartVideoTrack() {
        guard suspendedVideoID == nil, let track = videoTracks.first(where: \.isSelected) ?? videoTracks.first else { return }
        setProperty("vid", String(track.id))
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
        let chain =
            active
            .map { "equalizer=f=\($0.0):t=o:w=1:g=\(String(format: "%.1f", $0.1))" }
            .joined(separator: ",")
        setProperty("af", "lavfi=[\(chain)]")
    }

    func screenshot(includeSubtitles: Bool = true) {
        guard hasMedia else { return }
        AppPaths.ensureDirectories()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let title = Self.safeFilename(currentItem?.title ?? "Lumora")
        let url = AppPaths.screenshots.appendingPathComponent("\(title) \(formatter.string(from: Date())).png")
        nextReplyID += 1
        pendingScreenshots[nextReplyID] = url
        command(
            ["screenshot-to-file", url.path, includeSubtitles ? "subtitles" : "video"],
            replyID: nextReplyID
        )
    }

    /// Turns mpv's terse error codes into a sentence people can act on.
    private static func explain(_ code: Int32, isLocal: Bool) -> String {
        switch mpv_error(rawValue: code) {
        case MPV_ERROR_UNKNOWN_FORMAT:
            return "The format isn't recognized or the file is damaged."
        case MPV_ERROR_LOADING_FAILED:
            return isLocal
                ? "The file is missing, unreadable or damaged."
                : "The stream couldn't be opened. Check the link and your connection."
        case MPV_ERROR_NOTHING_TO_PLAY:
            return "It contains no audio or video Lumora can play."
        case MPV_ERROR_AO_INIT_FAILED:
            return "No audio output device is available."
        case MPV_ERROR_VO_INIT_FAILED:
            return "The video output couldn't start."
        default:
            return "(\(MPV.errorString(code)))"
        }
    }

    private static func safeToolPath(_ path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
            !trimmed.contains(","), !trimmed.contains("="),
            FileManager.default.isExecutableFile(atPath: trimmed)
        else { return fallback }
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
            isFileLoaded = true
            updateLiveState()
            hasPicture = !videoTracks.isEmpty
            DebugTimeline.log("file loaded")
            Self.releaseFreeMemory(after: 3)
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
                let title = currentItem?.title ?? "this file"
                hasMedia = false
                isPlaying = false
                statusMessage = "Couldn't play “\(title)”. \(Self.explain(endFile.error, isLocal: currentItem?.url.isFileURL ?? true))"
                onError?(statusMessage)
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            handleLog(data.assumingMemoryBound(to: mpv_event_log_message.self).pointee)
        case MPV_EVENT_GET_PROPERTY_REPLY:
            guard let pending = pendingReads.removeValue(forKey: event.reply_userdata) else { return }
            if event.error >= 0, let data = event.data {
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                if property.format == MPV_FORMAT_STRING, let raw = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                    pending.batch.values[pending.name] = String(cString: raw)
                }
            }
            pending.batch.remaining -= 1
            if pending.batch.remaining == 0 {
                pending.batch.completion(pending.batch.values)
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
            updateLiveState()
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
            } else if !reached {
                isAtEnd = false
            }
        case "paused-for-cache":
            isBuffering = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
            DebugTimeline.log(isBuffering ? "buffering start" : "buffering end")
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
            if voConfigured { DebugTimeline.log("video output ready (first frame)") }
        case "video-rotate":
            rotation = hasValue ? Int(property.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        case "edition-list":
            guard hasValue, currentItem.map({ !$0.url.isFileURL }) == true else {
                streamVariants = []
                return
            }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            let list = MPV.value(from: node) as? [Any] ?? []
            streamVariants = list.compactMap { entry in
                guard let map = entry as? [String: Any], let id = map.int("id"), let title = map.string("title") else { return nil }
                return StreamVariant(id: id, title: title, isSelected: id == currentEdition)
            }
        case "demuxer-cache-state":
            // Local files read ahead from disk; only streams show a buffer bar.
            guard hasValue, isStream else {
                if !bufferedRanges.isEmpty { bufferedRanges = [] }
                return
            }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            let state = MPV.value(from: node) as? [String: Any]
            let ranges = (state?["seekable-ranges"] as? [Any] ?? []).compactMap { entry -> ClosedRange<TimeInterval>? in
                guard let map = entry as? [String: Any], let start = map.double("start"), let end = map.double("end"), end > start
                else { return nil }
                return start...end
            }
            // The cache reports many times a second; publish only visible changes.
            let changed =
                ranges.count != bufferedRanges.count
                || zip(ranges, bufferedRanges).contains { abs($0.lowerBound - $1.lowerBound) > 0.5 || abs($0.upperBound - $1.upperBound) > 0.5 }
            if changed { bufferedRanges = ranges }
        case "media-title":
            // Streams open under their link; use the title mpv learns (yt-dlp, HLS, ICY).
            guard hasValue, isStream, var item = currentItem,
                let raw = property.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
            else { return }
            let title = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let looksLikeLink = title.contains("://") || title == item.url.lastPathComponent
            guard !title.isEmpty, !looksLikeLink, title != item.title else { return }
            item.title = title
            currentItem = item
            onTitleChange?(item)
        case "width":
            sourceSize.width = hasValue ? CGFloat(property.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        case "height":
            sourceSize.height = hasValue ? CGFloat(property.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        case "audio-device-list":
            guard hasValue else { return }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            let list = MPV.value(from: node) as? [Any] ?? []
            audioDevices = list.compactMap { entry in
                guard let map = entry as? [String: Any], let name = map.string("name") else { return nil }
                // mpv lists every Core Audio device twice ("coreaudio/<id>" and the exclusive
                // "coreaudio-exclusive/..."); exclusive mode isn't offered.
                guard name == "auto" || name.hasPrefix("coreaudio/") else { return nil }
                return (name, name == "auto" ? "System Default" : map.string("description") ?? name)
            }
        case "audio-device":
            if hasValue, let raw = property.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                audioDevice = String(cString: raw)
            }
        case "deinterlace":
            if hasValue, let raw = property.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                deinterlace = String(cString: raw)
            }
        case "partially-seekable":
            isPartiallySeekable = hasValue && property.data.assumingMemoryBound(to: Int32.self).pointee != 0
            updateLiveState()
        case "metadata":
            guard hasValue else {
                mediaTags = [:]
                return
            }
            let node = property.data.assumingMemoryBound(to: mpv_node.self).pointee
            let map = MPV.value(from: node) as? [String: Any] ?? [:]
            var tags: [String: String] = [:]
            for (key, value) in map {
                if let text = value as? String, !text.isEmpty { tags[key.lowercased()] = text }
            }
            mediaTags = tags
            updateLiveState()
        case "current-edition":
            currentEdition = hasValue ? Int(property.data.assumingMemoryBound(to: Int64.self).pointee) : -1
            streamVariants = streamVariants.map { variant in
                var copy = variant
                copy.isSelected = variant.id == currentEdition
                return copy
            }
        default:
            break
        }
    }

    /// Metal failure is detected from mpv's own error ("Error opening/initializing the selected
    /// video_out") rather than a timeout, so slow streams never trigger a false fallback.
    private func handleLog(_ message: mpv_event_log_message) {
        guard let text = message.text else { return }
        let line = String(cString: text)
        // Kept for a crash report on the next launch (scrubbed of names and paths before sending).
        let prefix = message.prefix.map { String(cString: $0) } ?? "mpv"
        SessionLog.record("[\(prefix)] \(line)")
        #if DEBUG
            if getenv("LUMORA_MPV_LOG") != nil {
                print("[mpv] [\(prefix)] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        #endif
        guard renderer == .metal, !pendingOpenGLSwitch else { return }
        if line.contains("selected video_out") || line.contains("suitable GPU context") {
            SessionLog.recordRendererFallback(reason: "[\(prefix)] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            onRendererFailure?()
        }
    }

    /// Reads several properties without blocking the main thread (mpv's video output may be
    /// waiting on it). Missing properties are left out of the result.
    func readProperties(_ names: [String], completion: @escaping ([String: String]) -> Void) {
        guard !isShutDown, !names.isEmpty else {
            completion([:])
            return
        }
        let batch = PropertyBatch(count: names.count, completion: completion)
        for name in names {
            nextReplyID += 1
            pendingReads[nextReplyID] = (name, batch)
            if mpv_get_property_async(handle, nextReplyID, name, MPV_FORMAT_STRING) < 0 {
                pendingReads.removeValue(forKey: nextReplyID)
                batch.remaining -= 1
            }
        }
        if batch.remaining == 0 {
            completion(batch.values)
        }
    }

    private func updateLiveState() {
        // Live: no known end, only the downloaded part can be seeked (a stream without a fixed
        // length), or Icecast/Shoutcast radio, which reports a growing "duration".
        let radio = mediaTags["icy-name"] != nil || mediaTags["icy-title"] != nil
        let channel = currentItem?.kind == .channel
        let live = isFileLoaded && isStream && (channel || duration <= 0 || isPartiallySeekable || radio)
        if live != isLive { isLive = live }
    }

    private func parseTracks(_ list: [Any]) {
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        var video: [MediaTrack] = []
        for entry in list {
            guard let map = entry as? [String: Any],
                let id = map.int("id"),
                let type = map.string("type"),
                let kind = TrackKind(rawValue: type)
            else { continue }
            let track = MediaTrack(
                id: id,
                kind: kind,
                title: map.string("title"),
                language: map.string("lang"),
                codec: map.string("codec"),
                isExternal: map.bool("external"),
                isSelected: map.bool("selected"),
                channels: map.string("demux-channels").flatMap { $0.hasPrefix("unknown") ? nil : $0 },
                bitrate: map.int("demux-bitrate") ?? 0
            )
            switch kind {
            case .audio: audio.append(track)
            case .subtitle: subtitles.append(track)
            case .video: video.append(track)
            }
        }
        let isStream = currentItem.map { !$0.url.isFileURL } ?? false
        audioTracks = isStream ? MediaTrack.collapsingStreamFormats(audio) : audio
        subtitleTracks = subtitles
        videoTracks = video
        if isFileLoaded {
            let picture = !video.isEmpty
            if picture != hasPicture { hasPicture = picture }
        }
    }
}

/// mpv's wakeup callback can fire for every video frame; schedule at most one main-thread drain
/// at a time, which then handles every queued event.
final class EngineWakeup: @unchecked Sendable {
    weak var object: PlaybackEngine?
    private let lock = NSLock()
    private var scheduled = false

    func schedule() {
        lock.lock()
        if scheduled {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            MainActor.assumeIsolated {
                object?.drainEvents()
            }
        }
    }
}

private func mpvWakeup(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<EngineWakeup>.fromOpaque(context).takeUnretainedValue().schedule()
}
