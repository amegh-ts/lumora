import AppKit
import MediaPlayer

/// Media keys, AirPods/headphone controls and the Control Center / lock screen "Now Playing" widget.
/// The player window that most recently started playing owns the system controls.
@MainActor
final class NowPlayingService {
    static let shared = NowPlayingService()

    static let skipInterval: TimeInterval = 10

    private weak var active: PlayerViewController?
    private var artworkToken = 0
    private var artworkItemID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var lastPublishedTime: TimeInterval = 0
    private var lastPublishedAt = Date()
    private var lastPublishedRate: Float = 0
    private var commandsInstalled = false
    private var publishScheduled = false

    private init() {}

    // MARK: - Ownership

    func playerDidStartPlaying(_ player: PlayerViewController) {
        installCommandsIfNeeded()
        if active !== player {
            active = player
            artwork = nil
            artworkItemID = nil
        }
        publish(force: true)
    }

    func playerDidChange(_ player: PlayerViewController) {
        guard active === player else { return }
        publish(force: true)
    }

    /// Called on every time update; republishes only after a seek, since the system extrapolates
    /// elapsed time from the playback rate on its own.
    func playerDidUpdateTime(_ player: PlayerViewController) {
        guard active === player else { return }
        let engine = player.engine
        let expected = lastPublishedTime + Date().timeIntervalSince(lastPublishedAt) * Double(lastPublishedRate)
        if abs(engine.currentTime - expected) > 1.5 {
            publish(force: true)
        }
    }

    func playerDidClose(_ player: PlayerViewController) {
        guard active === player else { return }
        active = nil
        clear()
    }

    // MARK: - Publishing

    /// Coalesces updates and waits one run-loop pass: @Published fires before the engine's
    /// property changes, and mpv applies commands asynchronously.
    private func publish(force: Bool) {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.publishNow()
        }
    }

    private func publishNow() {
        guard let player = active, let item = player.engine.currentItem, player.engine.hasMedia else {
            clear()
            return
        }
        let engine = player.engine
        let rate: Float = engine.isPlaying ? engine.rate : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: engine.videoTracks.isEmpty
                ? MPNowPlayingInfoMediaType.audio.rawValue
                : MPNowPlayingInfoMediaType.video.rawValue
        ]
        if engine.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = engine.duration
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(1, engine.currentTime / engine.duration)
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork, artworkItemID == item.id {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            requestArtwork(for: item, duration: engine.duration)
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = engine.isPlaying ? .playing : .paused
        lastPublishedTime = engine.currentTime
        lastPublishedAt = Date()
        lastPublishedRate = rate
        updateCommandAvailability()
    }

    private func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        artwork = nil
        artworkItemID = nil
    }

    private func requestArtwork(for item: PlaybackItem, duration: TimeInterval) {
        guard item.url.isFileURL, duration > 0, artworkItemID != item.id else { return }
        artworkItemID = item.id
        artworkToken += 1
        let token = artworkToken
        ThumbnailService.shared.request(url: item.url, time: duration * 0.1, duration: duration) { [weak self] image in
            guard let self, self.artworkToken == token, let image else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publish(force: true)
        }
    }

    // MARK: - Remote commands

    private func installCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let commands = MPRemoteCommandCenter.shared()

        target(commands.playCommand) { service, _ in service.perform { $0.engine.play() } }
        target(commands.pauseCommand) { service, _ in service.perform { $0.engine.pause() } }
        target(commands.togglePlayPauseCommand) { service, _ in service.perform { $0.engine.togglePlayback() } }
        target(commands.stopCommand) { service, _ in service.perform { $0.engine.pause() } }
        target(commands.nextTrackCommand) { service, _ in
            service.perform { $0.windowController?.playNext(auto: false) }
        }
        target(commands.previousTrackCommand) { service, _ in
            service.perform { $0.windowController?.playPrevious() }
        }
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        target(commands.skipForwardCommand) { service, _ in service.perform { $0.engine.skip(Self.skipInterval) } }
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        target(commands.skipBackwardCommand) { service, _ in service.perform { $0.engine.skip(-Self.skipInterval) } }
        target(commands.changePlaybackPositionCommand) { service, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return service.perform { $0.engine.seek(to: position) }
        }
        commands.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 2].map { NSNumber(value: $0) }
        target(commands.changePlaybackRateCommand) { service, event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            return service.perform { $0.engine.setRate(rate) }
        }
    }

    /// MediaPlayer delivers commands on the main thread.
    private func target(
        _ command: MPRemoteCommand,
        _ handler: @escaping @MainActor (NowPlayingService, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.addTarget { event in
            MainActor.assumeIsolated {
                handler(NowPlayingService.shared, event)
            }
        }
    }

    private func updateCommandAvailability() {
        let commands = MPRemoteCommandCenter.shared()
        let hasNeighbours = (active?.playlistCount ?? 0) > 1
        let seekable = (active?.engine.duration ?? 0) > 0
        commands.nextTrackCommand.isEnabled = hasNeighbours
        commands.previousTrackCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = seekable
        commands.skipForwardCommand.isEnabled = seekable
        commands.skipBackwardCommand.isEnabled = seekable
    }

    /// Runs a command on the active player and republishes; also used by the DEBUG harness.
    func perform(_ action: (PlayerViewController) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let player = active, player.engine.hasMedia else { return .noActionableNowPlayingItem }
        action(player)
        publish(force: true)
        return .success
    }
}
