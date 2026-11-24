import Foundation
import Combine

enum VideoGravityPreference: String, Codable, CaseIterable {
    case aspect
    case fill
    case stretch
}

enum VideoRenderer: String, Codable, CaseIterable {
    case metal
    case openGL = "opengl"

    var title: String {
        switch self {
        case .metal: return "Metal (gpu-next, HDR)"
        case .openGL: return "OpenGL (compatibility)"
        }
    }
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
    @Published var renderer: VideoRenderer = .metal { didSet { persist() } }
    @Published var subtitleDelay: TimeInterval = 0 { didSet { persist() } }
    @Published var autoDownloadSubtitles = false { didSet { persist() } }
    @Published var subtitleLanguages: String = "en" { didSet { persist() } }
    /// Stored in the login Keychain, never in settings.json.
    @Published var openSubtitlesAPIKey: String = "" {
        didSet {
            guard !isLoading, openSubtitlesAPIKey != oldValue else { return }
            Keychain.set(openSubtitlesAPIKey, for: Self.openSubtitlesAccount)
        }
    }
    private static let openSubtitlesAccount = "opensubtitles-api-key"
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
        var renderer: VideoRenderer?
    }

    private var migratedSecretsOutOfFile = false

    private init() {
        load()
        if migratedSecretsOutOfFile {
            persist()
        }
    }

    /// Restores every preference to its default. The OpenSubtitles API key is kept.
    func resetToDefaults() {
        let defaults = Snapshot()
        isLoading = true
        volume = defaults.volume
        rememberLastPosition = defaults.rememberLastPosition
        autoplayNext = defaults.autoplayNext
        repeatMode = defaults.repeatMode
        shuffle = defaults.shuffle
        videoGravity = defaults.videoGravity
        subtitleSize = defaults.subtitleSize
        subtitleDelay = defaults.subtitleDelay
        autoDownloadSubtitles = defaults.autoDownloadSubtitles
        subtitleLanguages = defaults.subtitleLanguages
        ytDLPPath = defaults.ytDLPPath
        ffmpegPath = defaults.ffmpegPath
        checkForUpdates = defaults.checkForUpdates
        hardwareDecoding = defaults.hardwareDecoding
        equalizerGains = defaults.equalizerGains
        brightness = defaults.brightness
        contrast = defaults.contrast
        saturation = defaults.saturation
        renderer = .metal
        isLoading = false
        persist()
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
        if !snapshot.openSubtitlesAPIKey.isEmpty {
            Keychain.set(snapshot.openSubtitlesAPIKey, for: Self.openSubtitlesAccount)
            migratedSecretsOutOfFile = true
        }
        openSubtitlesAPIKey = Keychain.string(for: Self.openSubtitlesAccount) ?? ""
        ytDLPPath = snapshot.ytDLPPath
        ffmpegPath = snapshot.ffmpegPath
        checkForUpdates = snapshot.checkForUpdates
        hardwareDecoding = snapshot.hardwareDecoding
        equalizerGains = snapshot.equalizerGains.count == 10 ? snapshot.equalizerGains : Array(repeating: 0, count: 10)
        brightness = snapshot.brightness
        contrast = snapshot.contrast
        saturation = snapshot.saturation
        renderer = snapshot.renderer ?? .metal
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
            openSubtitlesAPIKey: "",
            ytDLPPath: ytDLPPath,
            ffmpegPath: ffmpegPath,
            checkForUpdates: checkForUpdates,
            hardwareDecoding: hardwareDecoding,
            equalizerGains: equalizerGains,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            renderer: renderer
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppPaths.ensureDirectories()
        try? data.write(to: AppPaths.settingsFile, options: .atomic)
    }
}
