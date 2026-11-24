import Foundation
import Combine

enum VideoGravityPreference: String, Codable, CaseIterable {
    case aspect
    case fill
    case stretch
}

/// How text subtitles stand out from the picture.
enum SubtitleBackground: String, Codable, CaseIterable {
    case outline
    case shadow
    case box

    var title: String {
        switch self {
        case .outline: return "Outline"
        case .shadow: return "Drop shadow"
        case .box: return "Dark box"
        }
    }
}

/// When a newly opened file resizes the player window to the video.
enum WindowFitMode: String, Codable, CaseIterable {
    case always
    case firstFile
    case never

    var title: String {
        switch self {
        case .always: return "Every file"
        case .firstFile: return "First file only"
        case .never: return "Never"
        }
    }
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
    @Published var streamQuality: StreamQuality = .auto { didSet { persist() } }
    @Published var windowFit: WindowFitMode = .always { didSet { persist() } }
    @Published var subtitleFont: String = "" { didSet { persist() } }
    @Published var subtitleColor: String = "#FFFFFF" { didSet { persist() } }
    @Published var subtitleBackground: SubtitleBackground = .outline { didSet { persist() } }
    @Published var subtitlePosition: Double = 100 { didSet { persist() } }
    @Published var preferredAudioLanguages: String = "" { didSet { persist() } }
    @Published var preferredSubtitleLanguages: String = "" { didSet { persist() } }
    @Published var volumeBoost: Bool = false { didSet { persist() } }
    @Published var audioDevice: String = "auto" { didSet { persist() } }
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
        var streamQuality: StreamQuality = .auto
        var windowFit: WindowFitMode = .always
        var subtitleFont: String = ""
        var subtitleColor: String = "#FFFFFF"
        var subtitleBackground: SubtitleBackground = .outline
        var subtitlePosition: Double = 100
        var preferredAudioLanguages: String = ""
        var preferredSubtitleLanguages: String = ""
        var volumeBoost: Bool = false
        var audioDevice: String = "auto"

        init() {}

        /// Lenient: a missing or unknown field keeps its default instead of resetting everything.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
            }
            let d = Snapshot()
            volume = value(.volume, d.volume)
            rememberLastPosition = value(.rememberLastPosition, d.rememberLastPosition)
            autoplayNext = value(.autoplayNext, d.autoplayNext)
            repeatMode = value(.repeatMode, d.repeatMode)
            shuffle = value(.shuffle, d.shuffle)
            videoGravity = value(.videoGravity, d.videoGravity)
            subtitleSize = value(.subtitleSize, d.subtitleSize)
            subtitleDelay = value(.subtitleDelay, d.subtitleDelay)
            autoDownloadSubtitles = value(.autoDownloadSubtitles, d.autoDownloadSubtitles)
            subtitleLanguages = value(.subtitleLanguages, d.subtitleLanguages)
            openSubtitlesAPIKey = value(.openSubtitlesAPIKey, d.openSubtitlesAPIKey)
            ytDLPPath = value(.ytDLPPath, d.ytDLPPath)
            ffmpegPath = value(.ffmpegPath, d.ffmpegPath)
            checkForUpdates = value(.checkForUpdates, d.checkForUpdates)
            hardwareDecoding = value(.hardwareDecoding, d.hardwareDecoding)
            equalizerGains = value(.equalizerGains, d.equalizerGains)
            brightness = value(.brightness, d.brightness)
            contrast = value(.contrast, d.contrast)
            saturation = value(.saturation, d.saturation)
            renderer = value(.renderer, d.renderer)
            streamQuality = value(.streamQuality, d.streamQuality)
            windowFit = value(.windowFit, d.windowFit)
            subtitleFont = value(.subtitleFont, d.subtitleFont)
            subtitleColor = value(.subtitleColor, d.subtitleColor)
            subtitleBackground = value(.subtitleBackground, d.subtitleBackground)
            subtitlePosition = value(.subtitlePosition, d.subtitlePosition)
            preferredAudioLanguages = value(.preferredAudioLanguages, d.preferredAudioLanguages)
            preferredSubtitleLanguages = value(.preferredSubtitleLanguages, d.preferredSubtitleLanguages)
            volumeBoost = value(.volumeBoost, d.volumeBoost)
            audioDevice = value(.audioDevice, d.audioDevice)
        }
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
        streamQuality = defaults.streamQuality
        windowFit = defaults.windowFit
        subtitleFont = defaults.subtitleFont
        subtitleColor = defaults.subtitleColor
        subtitleBackground = defaults.subtitleBackground
        subtitlePosition = defaults.subtitlePosition
        preferredAudioLanguages = defaults.preferredAudioLanguages
        preferredSubtitleLanguages = defaults.preferredSubtitleLanguages
        volumeBoost = defaults.volumeBoost
        audioDevice = defaults.audioDevice
        isLoading = false
        persist()
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        // The API key lives in the Keychain, independent of settings.json being readable.
        openSubtitlesAPIKey = Keychain.string(for: Self.openSubtitlesAccount) ?? ""
        guard let data = try? Data(contentsOf: AppPaths.settingsFile) else { return }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            DataFileBackup.preserve(AppPaths.settingsFile)
            return
        }
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
        streamQuality = snapshot.streamQuality
        windowFit = snapshot.windowFit
        subtitleFont = snapshot.subtitleFont
        subtitleColor = snapshot.subtitleColor
        subtitleBackground = snapshot.subtitleBackground
        subtitlePosition = snapshot.subtitlePosition
        preferredAudioLanguages = snapshot.preferredAudioLanguages
        preferredSubtitleLanguages = snapshot.preferredSubtitleLanguages
        volumeBoost = snapshot.volumeBoost
        audioDevice = snapshot.audioDevice
    }

    func save() {
        flush()
    }

    private var persistWork: DispatchWorkItem?

    /// Debounced: sliders, trackpad volume and typing change settings many times a second.
    private func persist() {
        guard !isLoading else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeSettings() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately (quit, reset).
    func flush() {
        persistWork?.cancel()
        persistWork = nil
        writeSettings()
    }

    private func writeSettings() {
        var snapshot = Snapshot()
        snapshot.volume = volume
        snapshot.rememberLastPosition = rememberLastPosition
        snapshot.autoplayNext = autoplayNext
        snapshot.repeatMode = repeatMode
        snapshot.shuffle = shuffle
        snapshot.videoGravity = videoGravity
        snapshot.subtitleSize = subtitleSize
        snapshot.subtitleDelay = subtitleDelay
        snapshot.autoDownloadSubtitles = autoDownloadSubtitles
        snapshot.subtitleLanguages = subtitleLanguages
        snapshot.openSubtitlesAPIKey = ""
        snapshot.ytDLPPath = ytDLPPath
        snapshot.ffmpegPath = ffmpegPath
        snapshot.checkForUpdates = checkForUpdates
        snapshot.hardwareDecoding = hardwareDecoding
        snapshot.equalizerGains = equalizerGains
        snapshot.brightness = brightness
        snapshot.contrast = contrast
        snapshot.saturation = saturation
        snapshot.renderer = renderer
        snapshot.streamQuality = streamQuality
        snapshot.windowFit = windowFit
        snapshot.subtitleFont = subtitleFont
        snapshot.subtitleColor = subtitleColor
        snapshot.subtitleBackground = subtitleBackground
        snapshot.subtitlePosition = subtitlePosition
        snapshot.preferredAudioLanguages = preferredAudioLanguages
        snapshot.preferredSubtitleLanguages = preferredSubtitleLanguages
        snapshot.volumeBoost = volumeBoost
        snapshot.audioDevice = audioDevice
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        AppPaths.ensureDirectories()
        try? data.write(to: AppPaths.settingsFile, options: .atomic)
    }
}
