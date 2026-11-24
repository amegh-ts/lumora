import Foundation

/// Turns playlist files (.m3u, .m3u8, .pls) and YouTube playlist links into separate playlist
/// items, so each entry has its own title, resume time and Next/Previous step.
enum PlaylistImporter {
    struct Entry: Sendable {
        var url: URL
        var title: String?
    }

    static let fileExtensions: Set<String> = ["m3u", "m3u8", "pls"]

    /// Network schemes a playlist entry may use. Anything else (mpv's lavfi://, edl://, memory://,
    /// av://…) could make mpv generate or read data the user never chose, so it's dropped.
    static let allowedSchemes: Set<String> = ["http", "https", "rtsp", "rtsps", "rtmp", "rtmps", "mms", "ftp", "smb", "udp", "rtp", "srt"]

    // MARK: Files

    /// Entries of a local playlist file, or nil when the file isn't a list of media (an HLS
    /// stream playlist, which mpv plays as one stream, or an unreadable file).
    static func entries(inFile url: URL) -> [Entry]? {
        guard url.isFileURL, fileExtensions.contains(url.pathExtension.lowercased()),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 20_000_000
        else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let base = url.deletingLastPathComponent()
        let entries = url.pathExtension.lowercased() == "pls" ? parsePLS(text, base: base) : parseM3U(text, base: base)
        return entries.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parseM3U(_ text: String, base: URL) -> [Entry]? {
        var entries: [Entry] = []
        var pendingTitle: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                // HLS stream playlists list segments or variants: play them as one stream.
                if line.hasPrefix("#EXT-X-TARGETDURATION") || line.hasPrefix("#EXT-X-STREAM-INF") || line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                    return nil
                }
                if line.hasPrefix("#EXTINF:"), let comma = line.firstIndex(of: ",") {
                    let title = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    pendingTitle = title.isEmpty ? nil : title
                }
                continue
            }
            if let url = resolve(line, base: base) {
                entries.append(Entry(url: url, title: pendingTitle))
            }
            pendingTitle = nil
        }
        return entries
    }

    static func parsePLS(_ text: String, base: URL) -> [Entry] {
        var files: [Int: String] = [:]
        var titles: [Int: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("file"), let index = Int(key.dropFirst(4)) {
                files[index] = value
            } else if key.hasPrefix("title"), let index = Int(key.dropFirst(5)) {
                titles[index] = value
            }
        }
        return files.keys.sorted().compactMap { index in
            guard let path = files[index], let url = resolve(path, base: base) else { return nil }
            return Entry(url: url, title: titles[index].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Absolute URLs stay as they are; paths (including Windows-style ones) are relative to the list.
    private static func resolve(_ text: String, base: URL) -> URL? {
        if text.contains("://") {
            let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
            guard let url, let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "file" {
                return url.isFileURL ? url.standardizedFileURL : nil
            }
            return allowedSchemes.contains(scheme) ? url : nil
        }
        var path = text.replacingOccurrences(of: "\\", with: "/")
        // Other "scheme:" forms (lavfi:, edl:, memory:, file: without slashes) aren't paths.
        if let colon = path.firstIndex(of: ":"), path[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
            path[..<colon].count > 1
        {
            return nil
        }
        if !path.hasPrefix("/") {
            path = base.appendingPathComponent(path).path
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: YouTube playlists

    /// youtube.com/playlist?list=… or a video opened from a playlist (watch?v=…&list=…).
    static func isYouTubePlaylist(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.hasSuffix("youtube.com") || host == "youtu.be",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let list = items.first(where: { $0.name == "list" })?.value, !list.isEmpty
        else { return false }
        return true
    }

    /// The playlist's videos (at most 500) and the index of the video the link pointed at.
    static func youTubeEntries(for url: URL, ytdlPath: String) async -> (entries: [Entry], start: Int)? {
        let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        let listURL: URL = {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            components.path = "/playlist"
            components.queryItems = components.queryItems?.filter { $0.name == "list" }
            return components.url ?? url
        }()
        guard let data = await run(ytdlPath, ["--flat-playlist", "--playlist-end", "500", "-J", "--no-warnings", listURL.absoluteString]),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawEntries = json["entries"] as? [[String: Any]]
        else { return nil }
        var entries: [Entry] = []
        var start: Int?
        for raw in rawEntries {
            guard let id = raw["id"] as? String, let video = URL(string: "https://www.youtube.com/watch?v=\(id)") else { continue }
            if id == videoID {
                start = entries.count
            }
            entries.append(Entry(url: video, title: raw["title"] as? String))
        }
        guard !entries.isEmpty else { return nil }
        // The linked video may be beyond the first 500; keep it first so it still plays.
        if start == nil, let videoID, let video = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
            entries.insert(Entry(url: video, title: nil), at: 0)
        }
        return (entries, start ?? 0)
    }

    /// Runs a tool off the main thread with a 60 s limit; nil on failure.
    private static func run(_ path: String, _ arguments: [String]) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }
}
