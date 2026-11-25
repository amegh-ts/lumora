import Foundation

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one
}

enum PlaybackKind: String, Codable {
    case local
    case network
    /// A live TV channel from a channel list: no resume, no skipping on errors.
    case channel
}

struct PlaybackItem: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var kind: PlaybackKind
    /// Some streams only answer a particular browser identity or referring page (#EXTVLCOPT).
    var userAgent: String?
    var referrer: String?

    init(url: URL, title: String? = nil, kind: PlaybackKind? = nil, userAgent: String? = nil, referrer: String? = nil) {
        self.id = UUID()
        self.url = url
        self.kind = kind ?? (url.isFileURL ? .local : .network)
        self.title = title ?? Self.defaultTitle(for: url)
        self.userAgent = userAgent
        self.referrer = referrer
    }

    private static func defaultTitle(for url: URL) -> String {
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.absoluteString
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    let id: UUID
    var time: TimeInterval
    var label: String

    init(id: UUID = UUID(), time: TimeInterval, label: String) {
        self.id = id
        self.time = time
        self.label = label
    }
}

struct LibraryRecord: Codable, Identifiable, Hashable {
    var url: URL
    var title: String
    var resumeTime: TimeInterval
    var duration: TimeInterval
    var lastPlayed: Date
    var watched: Bool
    var bookmarks: [Bookmark]

    var id: String {
        url.absoluteString
    }

    init(
        url: URL,
        title: String,
        resumeTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        lastPlayed: Date = Date(),
        watched: Bool = false,
        bookmarks: [Bookmark] = []
    ) {
        self.url = url
        self.title = title
        self.resumeTime = resumeTime
        self.duration = duration
        self.lastPlayed = lastPlayed
        self.watched = watched
        self.bookmarks = bookmarks
    }

    /// Lenient: fields added in later versions default instead of failing the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? url.lastPathComponent
        resumeTime = try container.decodeIfPresent(TimeInterval.self, forKey: .resumeTime) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed) ?? .distantPast
        watched = try container.decodeIfPresent(Bool.self, forKey: .watched) ?? false
        bookmarks = (try? container.decodeIfPresent([Bookmark].self, forKey: .bookmarks)) ?? []
    }
}

/// Decodes an array element by element, skipping entries that fail instead of losing all of them.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        elements = result
    }

    private struct DiscardedValue: Decodable {}
}

enum DataFileBackup {
    /// Moves an unreadable data file aside so the next save can't silently replace it.
    static func preserve(_ url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(formatter.string(from: Date())).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

struct SubtitleTrack: Identifiable, Hashable {
    var id: String
    var title: String
    var language: String
    var isExternal: Bool
    var url: URL?
}

enum TrackKind: String {
    case video
    case audio
    case subtitle = "sub"
}

struct MediaTrack: Identifiable, Hashable {
    var id: Int
    var kind: TrackKind
    var title: String?
    var language: String?
    var codec: String?
    var isExternal: Bool
    var isSelected: Bool
    var channels: String?
    var bitrate: Int = 0

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append(title)
        }
        if let language, !language.isEmpty {
            let name = Locale.current.localizedString(forLanguageCode: language) ?? language
            if !parts.contains(name) {
                parts.append(name)
            }
        }
        if parts.isEmpty {
            parts.append("Track \(id)")
        }
        var details: [String] = []
        if let codec, !codec.isEmpty {
            details.append(codec.uppercased())
        }
        if let channels, !channels.isEmpty {
            details.append(channels)
        }
        if isExternal {
            details.append("external")
        }
        let base = parts.joined(separator: " · ")
        return details.isEmpty ? base : "\(base)  (\(details.joined(separator: ", ")))"
    }
}

extension MediaTrack {
    /// yt-dlp turns every audio format of an online video into its own track ("251 - audio only
    /// (medium)", "140-drc - …"). Keep one per language: the playing one, else the best format.
    static func collapsingStreamFormats(_ tracks: [MediaTrack]) -> [MediaTrack] {
        let isFormatList = tracks.count > 2 && tracks.allSatisfy { $0.title?.contains(" - ") == true }
        guard isFormatList else { return tracks }
        func score(_ track: MediaTrack) -> (Int, Int, Int) {
            let title = track.title?.lowercased() ?? ""
            let normal = title.contains("drc") ? 0 : 1
            let known = track.codec == nil ? 0 : 1
            return (known, normal, track.bitrate)
        }
        var order: [String] = []
        var groups: [String: [MediaTrack]] = [:]
        for track in tracks {
            let key = track.language ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            var chosen = group.first(where: \.isSelected) ?? group.max { score($0) < score($1) }!
            chosen.title = key.isEmpty ? (order.count == 1 ? "Original audio" : "Audio") : nil
            return chosen
        }
    }
}

struct Chapter: Hashable {
    var title: String
    var time: TimeInterval
}

struct SubtitleSearchResult: Identifiable, Hashable {
    var id: String
    var title: String
    var language: String
    var releaseName: String
    var fileID: Int
    var downloads: Int = 0
    var hearingImpaired = false
}

struct ConvertPreset: Identifiable, Hashable {
    var id: String
    var title: String
    var arguments: [String]
}
