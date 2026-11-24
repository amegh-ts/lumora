import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var records: [String: LibraryRecord] = [:]

    private init() {
        load()
    }

    func record(for url: URL) -> LibraryRecord? {
        records[url.absoluteString]
    }

    func ensureRecord(for item: PlaybackItem) -> LibraryRecord {
        if let existing = records[item.url.absoluteString] {
            return existing
        }
        let record = LibraryRecord(url: item.url, title: item.title)
        records[record.id] = record
        save()
        return record
    }

    func update(
        url: URL,
        title: String,
        resumeTime: TimeInterval,
        duration: TimeInterval,
        watched: Bool? = nil
    ) {
        var record = records[url.absoluteString] ?? LibraryRecord(url: url, title: title)
        record.title = title
        record.resumeTime = resumeTime
        record.duration = duration
        record.lastPlayed = Date()
        if let watched {
            record.watched = watched
        }
        records[record.id] = record
        save()
    }

    func markWatched(url: URL, title: String, duration: TimeInterval) {
        update(url: url, title: title, resumeTime: 0, duration: duration, watched: true)
    }

    func addBookmark(url: URL, time: TimeInterval, label: String) {
        var record = records[url.absoluteString] ?? LibraryRecord(url: url, title: url.lastPathComponent)
        record.bookmarks.append(Bookmark(time: time, label: label))
        record.bookmarks.sort { $0.time < $1.time }
        records[record.id] = record
        save()
    }

    func removeBookmark(url: URL, id: UUID) {
        guard var record = records[url.absoluteString] else { return }
        record.bookmarks.removeAll { $0.id == id }
        records[record.id] = record
        save()
    }

    func continueWatching(limit: Int = 12) -> [LibraryRecord] {
        records.values
            .filter { !$0.watched && $0.resumeTime > 30 && $0.duration > 0 }
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(limit)
            .map { $0 }
    }

    func recent(limit: Int = 24) -> [LibraryRecord] {
        records.values
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(limit)
            .map { $0 }
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        guard let decoded = try? JSONDecoder().decode([LibraryRecord].self, from: data) else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func save() {
        AppPaths.ensureDirectories()
        let data = try? JSONEncoder().encode(Array(records.values))
        try? data?.write(to: AppPaths.libraryFile, options: .atomic)
    }
}
