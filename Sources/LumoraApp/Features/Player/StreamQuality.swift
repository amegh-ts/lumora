import AppKit
import CoreMedia
import VideoToolbox

/// Default quality for online videos (YouTube and other yt-dlp sites).
enum StreamQuality: String, Codable, CaseIterable {
    case auto
    case best
    case p2160 = "2160"
    case p1440 = "1440"
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"
    case p360 = "360"

    var title: String {
        switch self {
        case .auto: return "Auto (match the display)"
        case .best: return "Best available"
        default: return "\(rawValue)p"
        }
    }

    /// Height cap for yt-dlp, or nil for no cap.
    @MainActor
    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .auto: return Self.displayHeight
        default: return Int(rawValue)
        }
    }

    private static let standardHeights = [4320, 2160, 1440, 1080, 720, 480, 360]

    /// Largest standard height a 16:9 video can use on the biggest connected display,
    /// so streams never download more pixels than the screen can show.
    @MainActor
    static var displayHeight: Int {
        let pixels = NSScreen.screens.map { screen -> CGFloat in
            let scale = screen.backingScaleFactor
            return min(screen.frame.height * scale, screen.frame.width * scale * 9 / 16)
        }
        let usable = Int(pixels.max() ?? 1080)
        return standardHeights.first { $0 <= usable } ?? 720
    }

    /// AV1 is only cheap when the media engine decodes it (M3 and later).
    static let hardwareAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// yt-dlp format selector for a height cap. Falls back step by step so every site still plays.
    static func ytdlFormat(maxHeight: Int?) -> String {
        let cap = maxHeight.map { "[height<=?\($0)]" } ?? ""
        let codec = hardwareAV1 ? "" : "[vcodec!^=av01]"
        var choices: [String] = []
        if !codec.isEmpty {
            choices.append("bestvideo\(cap)\(codec)+bestaudio")
        }
        choices.append("bestvideo\(cap)+bestaudio")
        choices.append("best\(cap)")
        choices.append("best")
        return choices.joined(separator: "/")
    }
}

/// One selectable rendition of a stream (a YouTube format or an HLS variant).
/// mpv exposes these as "editions"; switching edition swaps the video without reloading.
struct StreamVariant: Hashable {
    var id: Int
    var height: Int
    var fps: Int
    var codec: String?
    var kilobits: Int
    var isSelected: Bool

    var label: String {
        var text = height > 0 ? "\(height)p" : "Variant \(id + 1)"
        if fps > 30 {
            text += "\(fps)"
        }
        return text
    }

    var detail: String {
        var parts: [String] = []
        if let codec {
            parts.append(codec.uppercased())
        }
        if kilobits > 0 {
            parts.append(kilobits >= 1000 ? String(format: "%.1f Mbps", Double(kilobits) / 1000) : "\(kilobits) kbps")
        }
        return parts.joined(separator: " · ")
    }

    /// Parses mpv's edition title, e.g. "401 - 3840x2160 (2160p60) (av1 60 fps 8981 kbps)".
    init?(id: Int, title: String, isSelected: Bool) {
        self.id = id
        self.isSelected = isSelected
        height = Self.firstInt(in: title, pattern: #"\d+x(\d+)"#) ?? Self.firstInt(in: title, pattern: #"(\d{3,4})p"#) ?? 0
        fps = Self.firstInt(in: title, pattern: #"(\d+) fps"#) ?? Self.firstInt(in: title, pattern: #"\d{3,4}p(\d{2,3})"#) ?? 0
        kilobits = Self.firstInt(in: title, pattern: #"(\d+) kbps"#) ?? 0
        let lower = title.lowercased()
        codec = ["av1", "vp9", "hevc", "h265", "h264", "avc1", "vp8"].first { lower.contains($0) }
        if codec == "avc1" { codec = "h264" }
        if codec == "h265" { codec = "hevc" }
        guard height > 0 || kilobits > 0 else { return nil }
    }

    private static func firstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    /// Codecs the media engine decodes cheaply rank higher.
    private var codecScore: Int {
        switch codec {
        case "av1": return StreamQuality.hardwareAV1 ? 3 : 0
        case "vp9": return 2
        case "hevc", "h264": return 1
        default: return 0
        }
    }

    /// One entry per resolution: the highest frame rate, then the cheapest codec to decode,
    /// then the lower bitrate (the standard rendition rather than the "premium" one).
    static func menuChoices(from variants: [StreamVariant]) -> [StreamVariant] {
        // Variants without a known height (some HLS streams) stay apart by bitrate.
        let byHeight = Dictionary(grouping: variants) { $0.height > 0 ? $0.height : -$0.kilobits }
        return byHeight.values.compactMap { group in
            if let selected = group.first(where: \.isSelected) {
                return selected
            }
            return group.max { a, b in
                if a.fps != b.fps { return a.fps < b.fps }
                if a.codecScore != b.codecScore { return a.codecScore < b.codecScore }
                return a.kilobits > b.kilobits
            }
        }
        .sorted { $0.height != $1.height ? $0.height > $1.height : $0.kilobits > $1.kilobits }
    }
}
