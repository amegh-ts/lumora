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

    init(ytdlPath: String, hardwareDecoding: Bool) {
        guard let created = mpv_create() else {
            fatalError("libmpv could not be initialised")
        }
        handle = created
        wakeupBox = WeakBox<PlaybackEngine>()

        let options: [(String, String)] = [
            ("config", "no"),
            ("terminal", Self.mpvLogging ? "yes" : "no"),
            ("msg-level", "all=warn"),
            ("vo", "libmpv"),
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
        for (name, value) in options {
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

        let context = Unmanaged.passRetained(wakeupBox).toOpaque()
        mpv_set_wakeup_callback(handle, mpvWakeup, context)
    }

    isolated deinit {
        shutdown()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv_terminate_destroy(handle)
        Unmanaged.passUnretained(wakeupBox).release()
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
            MPV.command(handle, args)
        } else {
            pendingLoad = args
        }
        MPV.setProperty(handle, "pause", "no")
        onLoad?(item)
    }

    func renderContextReady() {
        guard !isRenderReady else { return }
        isRenderReady = true
        if let pendingLoad {
            self.pendingLoad = nil
            MPV.command(handle, pendingLoad)
        }
    }

    func play() {
        guard hasMedia else { return }
        if isAtEnd {
            seek(to: 0)
        }
        MPV.setProperty(handle, "pause", "no")
    }

    func pause() {
        MPV.setProperty(handle, "pause", "yes")
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func stop() {
        MPV.command(handle, ["stop"])
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
        MPV.command(handle, ["seek", String(bounded), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func skip(_ seconds: TimeInterval) {
        guard hasMedia else { return }
        MPV.command(handle, ["seek", String(seconds), "relative+exact"])
    }

    func setVolume(_ newValue: Float) {
        let bounded = min(max(newValue, 0), 1)
        volume = bounded
        MPV.setProperty(handle, "volume", String(Double(bounded) * 100))
        if bounded > 0, isMuted {
            MPV.setProperty(handle, "mute", "no")
        }
    }

    func toggleMute() {
        MPV.setProperty(handle, "mute", isMuted ? "no" : "yes")
    }

    func setRate(_ newValue: Float) {
        let bounded = min(max(newValue, 0.1), 8)
        rate = bounded
        MPV.setProperty(handle, "speed", String(Double(bounded)))
    }

    func stepFrame(forward: Bool) {
        guard hasMedia else { return }
        MPV.command(handle, [forward ? "frame-step" : "frame-back-step"])
    }

    func cycleABLoop() {
        guard hasMedia else { return }
        MPV.command(handle, ["ab-loop"])
    }

    func clearLoop() {
        MPV.setProperty(handle, "ab-loop-a", "no")
        MPV.setProperty(handle, "ab-loop-b", "no")
    }

    func selectAudioTrack(_ id: Int?) {
        MPV.setProperty(handle, "aid", id.map(String.init) ?? "no")
    }

    func selectSubtitleTrack(_ id: Int?) {
        MPV.setProperty(handle, "sid", id.map(String.init) ?? "no")
    }

    func addSubtitle(_ url: URL) {
        MPV.command(handle, ["sub-add", url.path, "select"])
    }

    func setSubtitleDelay(_ seconds: TimeInterval) {
        MPV.setProperty(handle, "sub-delay", String(seconds))
    }

    func setAudioDelay(_ seconds: TimeInterval) {
        MPV.setProperty(handle, "audio-delay", String(seconds))
    }

    func setSubtitleScale(_ scale: Double) {
        MPV.setProperty(handle, "sub-scale", String(min(max(scale, 0.3), 3)))
    }

    func setHardwareDecoding(_ enabled: Bool) {
        MPV.setProperty(handle, "hwdec", enabled ? "auto-safe" : "no")
    }

    func setVideoAdjustments(brightness: Double, contrast: Double, saturation: Double) {
        MPV.setProperty(handle, "brightness", String(Int((brightness * 100).rounded())))
        MPV.setProperty(handle, "contrast", String(Int(((contrast - 1) * 100).rounded())))
        MPV.setProperty(handle, "saturation", String(Int(((saturation - 1) * 100).rounded())))
    }

    func setGravity(_ preference: VideoGravityPreference) {
        switch preference {
        case .aspect:
            MPV.setProperty(handle, "keepaspect", "yes")
            MPV.setProperty(handle, "panscan", "0")
        case .fill:
            MPV.setProperty(handle, "keepaspect", "yes")
            MPV.setProperty(handle, "panscan", "1")
        case .stretch:
            MPV.setProperty(handle, "keepaspect", "no")
            MPV.setProperty(handle, "panscan", "0")
        }
    }

    func rotate() {
        MPV.setProperty(handle, "video-rotate", String((rotation + 90) % 360))
    }

    func setEqualizer(_ gains: [Double]) {
        let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let active = zip(frequencies, gains).filter { abs($0.1) >= 0.1 }
        guard !active.isEmpty else {
            MPV.setProperty(handle, "af", "")
            return
        }
        let chain = active
            .map { "equalizer=f=\($0.0):t=o:w=1:g=\(String(format: "%.1f", $0.1))" }
            .joined(separator: ",")
        MPV.setProperty(handle, "af", "lavfi=[\(chain)]")
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
        MPV.command(
            handle,
            ["screenshot-to-file", url.path, includeSubtitles ? "subtitles" : "video"],
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
        case "video-rotate":
            rotation = hasValue ? Int(property.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        default:
            break
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
