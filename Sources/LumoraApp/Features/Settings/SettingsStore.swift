import Foundation
import Combine

enum VideoGravityPreference: String, Codable, CaseIterable {
    case aspect
    case fill
    case stretch
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var volume: Float = 1 { didSet { persist() } }
    @Published var rememberLastPosition = true { didSet { persist() } }
    @Published var autoplayNext = true { didSet { persist() } }
    @Published var repeatMode: RepeatMode = .off { didSet { persist() } }
    @Published var shuffle = false { didSet { persist() } }
    @Published var videoGravity: VideoGravityPreference = .aspect { didSet { persist() } }
    @Published var subtitleSize: Double = 24 { didSet { persist() } }
    @Published var subtitleDelay: TimeInterval = 0 { didSet { persist() } }
    @Published var autoDownloadSubtitles = false { didSet { persist() } }
    @Published var subtitleLanguages: String = "en" { didSet { persist() } }
    @Published var openSubtitlesAPIKey: String = "" { didSet { persist() } }
    @Published var ytDLPPath: String = "/opt/homebrew/bin/yt-dlp" { didSet { persist() } }
    @Published var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg" { didSet { persist() } }
    @Published var checkForUpdates = true { didSet { persist() } }
    @Published var hardwareDecoding = true { didSet { persist() } }
    @Published var equalizerGains: [Double] = Array(repeating: 0, count: 10) { didSet { persist() } }
    @Published var brightness: Double = 0 { didSet { persist() } }
    @Published var contrast: Double = 1 { didSet { persist() } }
    @Published var saturation: Double = 1 { didSet { persist() } }

    private var isLoading = false

    private struct Snapshot: Codable {
        var volume: Float = 1
        var rememberLastPosition = true
        var autoplayNext = true
        var repeatMode: RepeatMode = .off
        var shuffle = false
        var videoGravity: VideoGravityPreference = .aspect
        var subtitleSize: Double = 24
        var subtitleDelay: TimeInterval = 0
        var autoDownloadSubtitles = false
        var subtitleLanguages: String = "en"
        var openSubtitlesAPIKey: String = ""
        var ytDLPPath: String = "/opt/homebrew/bin/yt-dlp"
        var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
        var checkForUpdates = true
        var hardwareDecoding = true
        var equalizerGains: [Double] = Array(repeating: 0, count: 10)
        var brightness: Double = 0
        var contrast: Double = 1
        var saturation: Double = 1
    }

    private init() {
        load()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: AppPaths.settingsFile) else { return }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        volume = snapshot.volume
        rememberLastPosition = snapshot.rememberLastPosition
        autoplayNext = snapshot.autoplayNext
        repeatMode = snapshot.repeatMode
        shuffle = snapshot.shuffle
        videoGravity = snapshot.videoGravity
        subtitleSize = snapshot.subtitleSize
        subtitleDelay = snapshot.subtitleDelay
        autoDownloadSubtitles = snapshot.autoDownloadSubtitles
        subtitleLanguages = snapshot.subtitleLanguages
        openSubtitlesAPIKey = snapshot.openSubtitlesAPIKey
        ytDLPPath = snapshot.ytDLPPath
        ffmpegPath = snapshot.ffmpegPath
        checkForUpdates = snapshot.checkForUpdates
        hardwareDecoding = snapshot.hardwareDecoding
        equalizerGains = snapshot.equalizerGains.count == 10 ? snapshot.equalizerGains : Array(repeating: 0, count: 10)
        brightness = snapshot.brightness
        contrast = snapshot.contrast
        saturation = snapshot.saturation
    }

    func save() {
        persist()
    }

    private func persist() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            volume: volume,
            rememberLastPosition: rememberLastPosition,
            autoplayNext: autoplayNext,
            repeatMode: repeatMode,
            shuffle: shuffle,
            videoGravity: videoGravity,
            subtitleSize: subtitleSize,
            subtitleDelay: subtitleDelay,
            autoDownloadSubtitles: autoDownloadSubtitles,
            subtitleLanguages: subtitleLanguages,
            openSubtitlesAPIKey: openSubtitlesAPIKey,
            ytDLPPath: ytDLPPath,
            ffmpegPath: ffmpegPath,
            checkForUpdates: checkForUpdates,
            hardwareDecoding: hardwareDecoding,
            equalizerGains: equalizerGains,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppPaths.ensureDirectories()
        try? data.write(to: AppPaths.settingsFile, options: .atomic)
    }
}
