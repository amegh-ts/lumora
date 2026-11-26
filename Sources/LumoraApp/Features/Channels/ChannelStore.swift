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
    @Published private(set) var channelsBySource: [UUID: [Channel]] = [:] {
        didSet { rebuildIndex() }
    }
    /// Favourite and recent channels by `Channel.key`.
    @Published private(set) var favourites: Set<String> = []
    @Published private(set) var recent: [String] = []
    @Published private(set) var loadingSources: Set<UUID> = []
    /// Every channel once, in list order, rebuilt when a list changes.
    @Published private(set) var all: [Channel] = []
    /// Channels that failed this session; dimmed and skipped when switching.
    @Published private(set) var unavailable: Set<String> = []

    private var byKey: [String: Channel] = [:]
    /// Channel numbers stay with a channel across list updates, like a TV's channel list.
    private var numbers: [String: Int] = [:]
    private var byNumber: [Int: String] = [:]

    nonisolated private static let maxListBytes = 40 * 1024 * 1024
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private var loaded = false

    nonisolated private static var folder: URL { AppPaths.applicationSupport.appendingPathComponent("Channels", isDirectory: true) }
    nonisolated private static var stateFile: URL { folder.appendingPathComponent("channels.json") }
    /// "v2": lists cached by 0.12.0 lack channel IDs, so their channels would get different
    /// identities (and numbers) than a fresh download; those caches are ignored and re-downloaded.
    nonisolated private static func cacheFile(_ id: UUID) -> URL { folder.appendingPathComponent("v2-\(id.uuidString).json") }

    private struct State: Codable {
        var sources: [ChannelSource] = []
        var favourites: [String] = []
        var recent: [String] = []
        var numbers: [String: Int]?
    }

    // MARK: Loading

    /// Last channel watched, kept outside the lists so the empty screen can offer it without
    /// loading Live TV.
    static var lastChannelName: String? { UserDefaults.standard.string(forKey: "lumora.tv.lastChannelName") }
    static var lastChannelKey: String? { UserDefaults.standard.string(forKey: "lumora.tv.lastChannelKey") }
    var isLoaded: Bool { loaded }

    /// Frees the channel lists after Live TV is closed; they reload from disk when needed again.
    func unload() {
        guard loaded, loadingSources.isEmpty else { return }
        loaded = false
        channelsBySource = [:]
        sources = []
        favourites = []
        recent = []
        unavailable = []
    }

    /// Reads saved lists (off the main thread) and refreshes any older than a day.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.stateFile), let state = try? JSONDecoder().decode(State.self, from: data) {
            sources = state.sources
            favourites = Set(state.favourites)
            recent = state.recent
            numbers = state.numbers ?? [:]
        }
        let ids = sources.map(\.id)
        let keep = Set(ids.map { Self.cacheFile($0).lastPathComponent } + [Self.stateFile.lastPathComponent])
        Task.detached(priority: .userInitiated) {
            // Remove caches no list uses any more (removed lists, the 0.12.0 format).
            if !DebugMode.background,
                let files = try? FileManager.default.contentsOfDirectory(at: ChannelStore.folder, includingPropertiesForKeys: nil)
            {
                for file in files where file.pathExtension == "json" && !keep.contains(file.lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
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
        Self.writeCache(channels, to: file)
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
        rebuildIndex()
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
                Self.writeCache(channels, to: file)
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

    // MARK: Index

    private func rebuildIndex() {
        var seen = Set<String>()
        var combined: [Channel] = []
        for source in sources {
            for channel in channelsBySource[source.id] ?? [] where seen.insert(channel.key).inserted {
                combined.append(channel)
            }
        }
        byKey = Dictionary(combined.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // New channels get the next free number; existing ones keep theirs.
        var next = (numbers.values.max() ?? 0) + 1
        var changed = false
        for channel in combined where numbers[channel.key] == nil {
            numbers[channel.key] = next
            next += 1
            changed = true
        }
        byNumber = Dictionary(numbers.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        all = combined.sorted { (numbers[$0.key] ?? 0) < (numbers[$1.key] ?? 0) }
        migrateLinkKeys()
        if changed {
            save()
        }
    }

    /// 0.12.0 stored favourites and recents by stream link; move them to channel keys.
    private func migrateLinkKeys() {
        guard favourites.contains(where: { $0.contains("://") }) || recent.contains(where: { $0.contains("://") }) else { return }
        let byLink = Dictionary(all.map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        guard !byLink.isEmpty else { return }
        favourites = Set(favourites.compactMap { $0.contains("://") ? byLink[$0] : $0 })
        var seen = Set<String>()
        recent = recent.compactMap { $0.contains("://") ? byLink[$0] : $0 }.filter { seen.insert($0).inserted }
        save()
    }

    func channel(forKey key: String) -> Channel? { byKey[key] }
    func channel(number: Int) -> Channel? { byNumber[number].flatMap { byKey[$0] } }
    func number(of channel: Channel) -> Int? { numbers[channel.key] }

    /// The channel a playing item belongs to (matched by link, then by name).
    func channel(for item: PlaybackItem) -> Channel? {
        all.first { $0.url == item.url } ?? all.first { $0.name == item.title }
    }

    var lastWatched: Channel? { recent.first.flatMap { byKey[$0] } }

    // MARK: Favourites, recents, availability

    func isFavourite(_ channel: Channel) -> Bool { favourites.contains(channel.key) }

    func toggleFavourite(_ channel: Channel) {
        if favourites.contains(channel.key) {
            favourites.remove(channel.key)
        } else {
            favourites.insert(channel.key)
        }
        save()
    }

    var favouriteChannels: [Channel] { all.filter { favourites.contains($0.key) } }
    var recentChannels: [Channel] { recent.compactMap { byKey[$0] } }

    func markWatched(_ channel: Channel) {
        if !DebugMode.background {
            UserDefaults.standard.set(channel.name, forKey: "lumora.tv.lastChannelName")
            UserDefaults.standard.set(channel.key, forKey: "lumora.tv.lastChannelKey")
        }
        unavailable.remove(channel.key)
        recent.removeAll { $0 == channel.key }
        recent.insert(channel.key, at: 0)
        if recent.count > 30 {
            recent.removeLast(recent.count - 30)
        }
        save()
    }

    func markUnavailable(_ channel: Channel) {
        unavailable.insert(channel.key)
    }

    func isUnavailable(_ channel: Channel) -> Bool { unavailable.contains(channel.key) }

    // MARK: Saving

    private static func writeCache(_ channels: [Channel], to file: URL) {
        // Background test runs (LUMORA_BACKGROUND, DEBUG only) must not change real data.
        guard !DebugMode.background else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: ChannelStore.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(channels) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func save() {
        // Background test runs (LUMORA_BACKGROUND, DEBUG only) must not change real data.
        guard !DebugMode.background else { return }
        let state = State(sources: sources, favourites: Array(favourites), recent: recent, numbers: numbers)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: ChannelStore.folder, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: ChannelStore.stateFile, options: .atomic)
            }
        }
    }
}
