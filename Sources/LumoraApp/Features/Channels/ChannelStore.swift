import Combine
import Foundation

/// Channel lists the user added, their channels (cached on disk), favourites and recently
/// watched channels. Lists refresh in the background once a day.
@MainActor
final class ChannelStore: ObservableObject {
    static let shared = ChannelStore()

    /// iptv-org's public list of free channels, offered when adding a list.
    static let presets: [(name: String, url: String)] = [
        ("All free channels (iptv-org)", "https://iptv-org.github.io/iptv/index.m3u"),
        ("Grouped by country (iptv-org)", "https://iptv-org.github.io/iptv/index.country.m3u"),
        ("News (iptv-org)", "https://iptv-org.github.io/iptv/categories/news.m3u"),
        ("Movies (iptv-org)", "https://iptv-org.github.io/iptv/categories/movies.m3u"),
        ("Music (iptv-org)", "https://iptv-org.github.io/iptv/categories/music.m3u"),
        ("Sports (iptv-org)", "https://iptv-org.github.io/iptv/categories/sports.m3u")
    ]

    @Published private(set) var sources: [ChannelSource] = []
    @Published private(set) var channelsBySource: [UUID: [Channel]] = [:]
    @Published private(set) var favourites: Set<String> = []
    @Published private(set) var recent: [String] = []
    @Published private(set) var loadingSources: Set<UUID> = []

    nonisolated private static let maxListBytes = 40 * 1024 * 1024
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private var loaded = false

    nonisolated private static var folder: URL { AppPaths.applicationSupport.appendingPathComponent("Channels", isDirectory: true) }
    nonisolated private static var stateFile: URL { folder.appendingPathComponent("channels.json") }
    nonisolated private static func cacheFile(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private struct State: Codable {
        var sources: [ChannelSource] = []
        var favourites: [String] = []
        var recent: [String] = []
    }

    // MARK: Loading

    /// Reads saved lists (off the main thread) and refreshes any older than a day.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.stateFile), let state = try? JSONDecoder().decode(State.self, from: data) {
            sources = state.sources
            favourites = Set(state.favourites)
            recent = state.recent
        }
        let ids = sources.map(\.id)
        Task.detached(priority: .userInitiated) {
            var cached: [UUID: [Channel]] = [:]
            for id in ids {
                if let data = try? Data(contentsOf: ChannelStore.cacheFile(id)), let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                    cached[id] = channels
                }
            }
            await MainActor.run {
                ChannelStore.shared.channelsBySource.merge(cached) { current, _ in current }
                ChannelStore.shared.refreshStale()
            }
        }
    }

    private func refreshStale() {
        for source in sources where source.lastUpdated.map({ Date().timeIntervalSince($0) > Self.refreshInterval }) ?? true {
            refresh(source.id)
        }
    }

    // MARK: Sources

    /// Adds a list and downloads it. Returns the new source's id.
    /// Adds a list that was already downloaded (Open URL checked it first).
    @discardableResult
    func addSource(url: URL, channels: [Channel]) -> UUID {
        loadIfNeeded()
        if let existing = sources.first(where: { $0.url == url }) {
            return existing.id
        }
        var source = ChannelSource(name: Self.defaultName(for: url), url: url)
        source.channelCount = channels.count
        source.lastUpdated = Date()
        sources.append(source)
        channelsBySource[source.id] = channels
        let file = Self.cacheFile(source.id)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: ChannelStore.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(channels) {
                try? data.write(to: file, options: .atomic)
            }
        }
        save()
        return source.id
    }

    @discardableResult
    func addSource(url: URL, name: String? = nil) -> UUID {
        loadIfNeeded()
        if let existing = sources.first(where: { $0.url == url }) {
            refresh(existing.id)
            return existing.id
        }
        let title = name?.isEmpty == false ? name! : Self.defaultName(for: url)
        let source = ChannelSource(name: title, url: url)
        sources.append(source)
        save()
        refresh(source.id)
        return source.id
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        sources[index].name = name
        save()
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        channelsBySource[id] = nil
        try? FileManager.default.removeItem(at: Self.cacheFile(id))
        save()
    }

    static func defaultName(for url: URL) -> String {
        if url.host?.contains("iptv-org") == true {
            let file = url.deletingPathExtension().lastPathComponent
            return file == "index" ? "iptv-org" : "iptv-org · \(file.capitalized)"
        }
        return url.isFileURL ? url.deletingPathExtension().lastPathComponent : (url.host ?? "Channel List")
    }

    /// Downloads (or re-reads) a list and replaces its channels; keeps the old ones on failure.
    func refresh(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }), !loadingSources.contains(id) else { return }
        loadingSources.insert(id)
        Task {
            let result = await Self.fetch(source.url)
            loadingSources.remove(id)
            guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let channels):
                channelsBySource[id] = channels
                sources[index].channelCount = channels.count
                sources[index].lastUpdated = Date()
                sources[index].lastError = nil
                let file = Self.cacheFile(id)
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: ChannelStore.folder, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(channels) {
                        try? data.write(to: file, options: .atomic)
                    }
                }
            case .failure(let error):
                sources[index].lastError = error.message
            }
            save()
        }
    }

    enum FetchError: Error {
        case network(String)
        case tooLarge
        case notAList
        case streamPlaylist

        var message: String {
            switch self {
            case .network(let reason): return "Couldn't download the list (\(reason))."
            case .tooLarge: return "The list is larger than 40 MB."
            case .notAList: return "No channels were found in this list."
            case .streamPlaylist: return "This link is a single stream, not a channel list."
            }
        }
    }

    /// Downloads and parses a channel list off the main thread.
    nonisolated static func fetch(_ url: URL) async -> Result<[Channel], FetchError> {
        let data: Data
        if url.isFileURL {
            guard let local = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.network("file not readable")) }
            data = local
        } else {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue("Lumora", forHTTPHeaderField: "User-Agent")
            switch await CappedDownload.data(for: request, maxBytes: maxListBytes) {
            case .success(let downloaded): data = downloaded
            case .failure(.tooLarge): return .failure(.tooLarge)
            case .failure(.http(let code)): return .failure(.network("HTTP \(code)"))
            case .failure(.network(let reason)): return .failure(.network(reason))
            }
        }
        guard data.count <= maxListBytes else { return .failure(.tooLarge) }
        return await Task.detached(priority: .userInitiated) { () -> Result<[Channel], FetchError> in
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            if ChannelListParser.isStreamPlaylist(text) { return .failure(.streamPlaylist) }
            let channels = ChannelListParser.parse(text, allowLocalFiles: url.isFileURL, base: url.deletingLastPathComponent())
            return channels.isEmpty ? .failure(.notAList) : .success(channels)
        }.value
    }

    // MARK: Favourites and recents

    func isFavourite(_ channel: Channel) -> Bool { favourites.contains(channel.id) }

    func toggleFavourite(_ channel: Channel) {
        if favourites.contains(channel.id) {
            favourites.remove(channel.id)
        } else {
            favourites.insert(channel.id)
        }
        save()
    }

    func markWatched(_ url: URL) {
        let id = url.absoluteString
        guard allChannels.contains(where: { $0.id == id }) else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 30 {
            recent.removeLast(recent.count - 30)
        }
        save()
    }

    /// Every channel once, in source order (a channel in two lists appears once).
    var allChannels: [Channel] {
        var seen = Set<String>()
        return sources.flatMap { channelsBySource[$0.id] ?? [] }.filter { seen.insert($0.id).inserted }
    }

    func channel(withID id: String) -> Channel? {
        for source in sources {
            if let match = channelsBySource[source.id]?.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: Saving

    private func save() {
        // Background test runs (LUMORA_BACKGROUND, DEBUG only) must not change real data.
        guard !DebugMode.background else { return }
        let state = State(sources: sources, favourites: Array(favourites), recent: recent)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: ChannelStore.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: ChannelStore.stateFile, options: .atomic)
            }
        }
    }
}
