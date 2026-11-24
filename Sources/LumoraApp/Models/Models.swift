import Foundation

enum RepeatMode: String, Codable, CaseIterable {
    case off
    case all
    case one
}

enum PlaybackKind: String, Codable {
    case local
    case network
}

struct PlaybackItem: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var kind: PlaybackKind

    init(url: URL, title: String? = nil, kind: PlaybackKind? = nil) {
        self.id = UUID()
        self.url = url
        self.kind = kind ?? (url.isFileURL ? .local : .network)
        self.title = title ?? Self.defaultTitle(for: url)
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
}

struct ConvertPreset: Identifiable, Hashable {
    var id: String
    var title: String
    var arguments: [String]
}
