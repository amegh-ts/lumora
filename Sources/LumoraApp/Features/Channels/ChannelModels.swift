import Foundation

/// One TV or radio channel from a channel list (M3U).
struct Channel: Codable, Hashable, Identifiable, Sendable {
    var url: URL
    var name: String
    var group: String
    var logo: URL?
    /// Two-letter country code, from the channel's tvg-id ("name.us@HD") when it has one.
    var country: String?
    var userAgent: String?
    var referrer: String?

    var id: String { url.absoluteString }

    var playbackItem: PlaybackItem {
        PlaybackItem(url: url, title: name, kind: .channel, userAgent: userAgent, referrer: referrer)
    }

    var countryName: String? {
        country.flatMap { Locale.current.localizedString(forRegionCode: $0.uppercased()) }
    }
}

/// A channel list the user added (a URL, or a file on this Mac).
struct ChannelSource: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var url: URL
    var lastUpdated: Date?
    var channelCount: Int
    var lastError: String?

    init(name: String, url: URL) {
        id = UUID()
        self.name = name
        self.url = url
        channelCount = 0
    }
}

enum ChannelListParser {
    /// True for HLS stream playlists (segments or quality variants of one stream), which play
    /// as a single stream rather than a list of channels.
    static func isStreamPlaylist(_ text: String) -> Bool {
        text.contains("#EXT-X-TARGETDURATION") || text.contains("#EXT-X-STREAM-INF") || text.contains("#EXT-X-MEDIA-SEQUENCE")
    }

    /// Parses an extended M3U channel list.
    ///
    /// Reads `#EXTINF` attributes (tvg-name, tvg-logo, tvg-id, group-title, and the user-agent /
    /// http-referrer some lists put there) and VLC's `#EXTVLCOPT:http-user-agent=` and
    /// `http-referrer=` lines. Lists downloaded from the internet may only point at network
    /// streams; entries for files on this Mac are dropped.
    static func parse(_ text: String, allowLocalFiles: Bool = false, base: URL? = nil) -> [Channel] {
        var channels: [Channel] = []
        var seen = Set<String>()
        var name: String?
        var attributes: [String: String] = [:]
        var userAgent: String?
        var referrer: String?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                let info = String(line.dropFirst(8))
                attributes = parseAttributes(info)
                name = commaTitle(info)
                userAgent = attributes["user-agent"] ?? attributes["http-user-agent"]
                referrer = attributes["http-referrer"] ?? attributes["referrer"]
                continue
            }
            if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst(11)
                if let value = option.split(separator: "=", maxSplits: 1).last, option.hasPrefix("http-user-agent=") {
                    userAgent = String(value)
                } else if let value = option.split(separator: "=", maxSplits: 1).last, option.hasPrefix("http-referrer=") {
                    referrer = String(value)
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            defer {
                name = nil
                attributes = [:]
                userAgent = nil
                referrer = nil
            }
            guard let url = resolve(line, allowLocalFiles: allowLocalFiles, base: base), seen.insert(url.absoluteString).inserted else { continue }
            let title = [name, attributes["tvg-name"]].compactMap { $0 }.first { !$0.isEmpty } ?? url.lastPathComponent
            let group = attributes["group-title"].flatMap { $0.isEmpty ? nil : $0.components(separatedBy: ";").first } ?? "Other"
            channels.append(
                Channel(
                    url: url,
                    name: title,
                    group: group == "Undefined" ? "Other" : group,
                    logo: attributes["tvg-logo"].flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    country: country(fromTVGID: attributes["tvg-id"]) ?? attributes["tvg-country"].flatMap { $0.count == 2 ? $0.lowercased() : nil },
                    userAgent: userAgent,
                    referrer: referrer
                ))
        }
        return channels
    }

    /// `key="value"` pairs before the title comma.
    private static func parseAttributes(_ info: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#) else { return result }
        let range = NSRange(info.startIndex..., in: info)
        for match in regex.matches(in: info, range: range) {
            if let key = Range(match.range(at: 1), in: info), let value = Range(match.range(at: 2), in: info) {
                result[info[key].lowercased()] = String(info[value])
            }
        }
        return result
    }

    /// The display name after the last comma that isn't inside quotes.
    private static func commaTitle(_ info: String) -> String? {
        var inQuotes = false
        var lastComma: String.Index?
        for index in info.indices {
            let character = info[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                lastComma = index
            }
        }
        guard let lastComma else { return nil }
        let title = info[info.index(after: lastComma)...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// "1Plus1International.ua@HD" → "ua".
    private static func country(fromTVGID id: String?) -> String? {
        guard let id, let dot = id.lastIndex(of: ".") else { return nil }
        let code = id[id.index(after: dot)...].prefix { $0.isLetter }
        return code.count == 2 ? code.lowercased() : nil
    }

    private static func resolve(_ text: String, allowLocalFiles: Bool, base: URL?) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), PlaylistImporter.allowedSchemes.contains(scheme) {
            return url
        }
        guard allowLocalFiles, let base else { return nil }
        return PlaylistImporter.parseM3U(text, base: base)?.first?.url
    }
}
