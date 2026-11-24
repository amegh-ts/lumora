import AppKit
import AVFoundation
import Combine

@MainActor
final class PlaybackEngine: ObservableObject {
    let player = AVPlayer()

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isPlaying = false
    @Published var volume: Float = 1
    @Published var rate: Float = 1
    @Published var statusMessage = "No media loaded"
    @Published var isExternalPlaybackActive = false
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var selectedAudioTrackID: Int32?
    @Published var selectedSubtitleTrackID: Int32?
    @Published var loopA: TimeInterval?
    @Published var loopB: TimeInterval?

    private(set) var currentItem: PlaybackItem?
    var onLoad: ((PlaybackItem) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?

    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingResumeTime: TimeInterval?
    private var volumeBeforeMute: Float = 1

    init() {
        player.allowsExternalPlayback = true
        player.volume = volume
        installPlayerObservers()
    }

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        rateObservation?.invalidate()
        externalObservation?.invalidate()
        itemStatusObservation?.invalidate()
        durationObservation?.invalidate()
    }

    func load(_ item: PlaybackItem, resumeTime: TimeInterval = 0) {
        stopItemObservers()
        currentItem = item
        pendingResumeTime = resumeTime
        duration = 0
        currentTime = 0
        loopA = nil
        loopB = nil
        statusMessage = "Loading \(item.title)…"

        let asset = AVURLAsset(
            url: item.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.replaceCurrentItem(with: playerItem)
        installItemObservers(on: playerItem)
        onLoad?(item)
        play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        pause()
        stopItemObservers()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentTime = 0
        duration = 0
        statusMessage = "No media loaded"
        audioTracks = []
        subtitleTracks = []
    }

    func seek(to time: TimeInterval) {
        guard let item = player.currentItem else { return }
        let bounded = min(max(time, 0), duration > 0 ? duration : time)
        let target = CMTime(seconds: bounded, preferredTimescale: 600)
        item.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                self?.currentTime = bounded
            }
        }
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setVolume(_ newValue: Float) {
        volume = min(max(newValue, 0), 1)
        player.volume = volume
        if volume > 0 {
            volumeBeforeMute = volume
        }
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            setVolume(0)
        } else {
            setVolume(volumeBeforeMute > 0 ? volumeBeforeMute : 1)
        }
    }

    func setRate(_ newValue: Float) {
        rate = min(max(newValue, 0.25), 4)
        if isPlaying {
            player.rate = rate
        }
    }

    func stepFrame(_ count: Int = 1) {
        pause()
        player.currentItem?.step(byCount: count)
    }

    func markLoopStart() {
        loopA = currentTime
        if let loopB, loopB <= currentTime {
            self.loopB = nil
        }
    }

    func markLoopEnd() {
        loopB = currentTime
        if let loopA, loopA >= currentTime {
            self.loopA = nil
        }
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
    }

    func selectAudioTrack(_ id: Int32?) {
        guard let item = player.currentItem else { return }
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = id == nil || track.assetTrack?.trackID == id
        }
        selectedAudioTrackID = id
    }

    func selectSubtitleTrack(_ id: Int32?) {
        guard let item = player.currentItem else { return }
        for track in item.tracks where track.assetTrack?.mediaType == .subtitle {
            track.isEnabled = track.assetTrack?.trackID == id
        }
        selectedSubtitleTrackID = id
    }

    func screenshot() -> URL? {
        guard let asset = player.currentItem?.asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let targetTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: targetTime, actualTime: nil) else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return nil }
        AppPaths.ensureDirectories()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "\(currentItem?.title ?? "Lumora")-\(formatter.string(from: Date())).png"
        let url = AppPaths.screenshots.appendingPathComponent(filename)
        try? data.write(to: url)
        return url
    }

    private func installPlayerObservers() {
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.rate > 0.01
            }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isExternalPlaybackActive = player.isExternalPlaybackActive
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handle(time: time)
            }
        }
    }

    private func installItemObservers(on item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handle(status: item.status, error: item.error)
            }
        }
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                let seconds = item.duration.seconds
                self?.duration = seconds.isFinite ? seconds : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleFinish()
            }
        }
    }

    private func stopItemObservers() {
        itemStatusObservation?.invalidate()
        durationObservation?.invalidate()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        itemStatusObservation = nil
        durationObservation = nil
        pendingResumeTime = nil
    }

    private func handle(status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            statusMessage = ""
            loadTracks()
            if let pendingResumeTime, pendingResumeTime > 0 {
                self.pendingResumeTime = nil
                seek(to: pendingResumeTime)
            }
            if isPlaying {
                player.play()
            }
        case .failed:
            let message = error?.localizedDescription ?? "The media could not be opened."
            statusMessage = message
            onError?(message)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handle(time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let loopA, let loopB, loopB > loopA, seconds >= loopB {
            seek(to: loopA)
        }
    }

    private func handleFinish() {
        isPlaying = false
        statusMessage = "Finished"
        onFinish?()
    }

    private func loadTracks() {
        guard let item = player.currentItem else { return }
        Task { @MainActor in
            var tracks: [MediaTrack] = []
            for itemTrack in item.tracks {
                guard let assetTrack = itemTrack.assetTrack else { continue }
                let language = (try? await assetTrack.load(.languageCode)) ?? "Unknown"
                let title = language == "Unknown" ? assetTrack.mediaType.rawValue.capitalized : language
                tracks.append(
                    MediaTrack(
                        id: assetTrack.trackID,
                        title: title,
                        language: language,
                        mediaType: assetTrack.mediaType
                    )
                )
            }
            audioTracks = tracks.filter { $0.mediaType == .audio }
            subtitleTracks = tracks.filter { $0.mediaType == .subtitle }
            if selectedAudioTrackID == nil {
                selectedAudioTrackID = audioTracks.first?.id
            }
            if selectedSubtitleTrackID == nil {
                selectedSubtitleTrackID = nil
            }
        }
    }
}
