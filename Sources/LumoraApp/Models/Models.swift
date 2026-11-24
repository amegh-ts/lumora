import Foundation
import AVFoundation

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

struct SubtitleCue: Codable, Identifiable, Hashable {
    let id: UUID
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }
}

struct SubtitleTrack: Identifiable, Hashable {
    var id: String
    var title: String
    var language: String
    var isExternal: Bool
    var url: URL?
}

struct MediaTrack: Identifiable, Hashable {
    var id: Int32
    var title: String
    var language: String
    var mediaType: AVMediaType
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

enum UpdateInfo {
    case upToDate
    case available(version: String, notes: String, download: URL?)
    case failure(String)
}
