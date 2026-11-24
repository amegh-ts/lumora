import Foundation

enum SubtitleService {
    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub", "idx", "sup"]

    static func isSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func saveDownloaded(_ data: Data, language: String, filename: String) -> SubtitleTrack? {
        AppPaths.ensureDirectories()
        let cleanLanguage = sanitizedLanguage(language)
        let baseName = sanitizedComponent((filename as NSString).deletingPathExtension)
        var ext = (filename as NSString).pathExtension.lowercased()
        if !["srt", "vtt", "ass", "ssa"].contains(ext) {
            ext = "srt"
        }
        let directory = AppPaths.subtitleCache.standardizedFileURL
        let url =
            directory
            .appendingPathComponent("\(cleanLanguage)-\(UUID().uuidString.prefix(8))-\(baseName)")
            .appendingPathExtension(ext)
            .standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.path else { return nil }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return SubtitleTrack(
            id: url.path,
            title: baseName,
            language: cleanLanguage,
            isExternal: true,
            url: url
        )
    }

    private static func sanitizedLanguage(_ language: String) -> String {
        let lower = language.lowercased()
        let valid = lower.range(of: "^[a-z]{2,3}(-[a-z]{2,4})?$", options: .regularExpression) != nil
        return valid ? lower : "und"
    }

    private static func sanitizedComponent(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let collapsed = mapped.replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let limited = String(collapsed.prefix(80))
        return limited.isEmpty ? "subtitle" : limited
    }
}
