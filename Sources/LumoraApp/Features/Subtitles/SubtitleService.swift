import Foundation

enum SubtitleService {
    static let supportedExtensions = ["srt", "vtt", "ass", "ssa"]

    static func sidecarTracks(for mediaURL: URL) -> [SubtitleTrack] {
        guard mediaURL.isFileURL else { return [] }
        let directory = mediaURL.deletingLastPathComponent()
        let baseName = mediaURL.deletingPathExtension().lastPathComponent
        let candidateDirectories = [directory, directory.appendingPathComponent("Subtitles", isDirectory: true)]
        var tracks: [SubtitleTrack] = []
        for candidateDirectory in candidateDirectories {
            guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: candidateDirectory.path) else { continue }
            for filename in filenames {
                let lower = filename.lowercased()
                guard let ext = lower.split(separator: ".").last.map(String.init), supportedExtensions.contains(ext) else { continue }
                let fileBase = (filename as NSString).deletingPathExtension
                guard fileBase == baseName || candidateDirectory.lastPathComponent == "Subtitles" else { continue }
                let url = candidateDirectory.appendingPathComponent(filename)
                tracks.append(
                    SubtitleTrack(
                        id: url.absoluteString,
                        title: (filename as NSString).deletingPathExtension,
                        language: detectLanguage(from: filename),
                        isExternal: true,
                        url: url
                    )
                )
            }
        }
        return tracks.sorted { $0.title < $1.title }
    }

    static func cues(at url: URL) -> [SubtitleCue] {
        guard let text = readText(url) else { return [] }
        let ext = url.pathExtension.lowercased()
        if ext == "ass" || ext == "ssa" {
            return parseASS(text)
        }
        return parseTimingFormat(text)
    }

    static func saveDownloaded(_ data: Data, language: String, filename: String) -> SubtitleTrack? {
        AppPaths.ensureDirectories()
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let url = AppPaths.subtitleCache.appendingPathComponent("\(language)-\(UUID().uuidString)-\(safeName)")
        guard (try? data.write(to: url)) != nil else { return nil }
        return SubtitleTrack(
            id: url.absoluteString,
            title: (filename as NSString).deletingPathExtension,
            language: language,
            isExternal: true,
            url: url
        )
    }

    private static func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func detectLanguage(from filename: String) -> String {
        let lower = filename.lowercased()
        let codes = ["en", "fr", "de", "es", "it", "ja", "ko", "zh", "pt", "ru", "ar", "hi"]
        for code in codes where lower.contains(".\(code).") || lower.contains("-\(code).") || lower.hasPrefix("\(code).") {
            return code
        }
        return "und"
    }

    private static func parseTimingFormat(_ text: String) -> [SubtitleCue] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            guard let timing = timingTimes(from: lines[index]) else {
                index += 1
                continue
            }
            var textLines: [String] = []
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    break
                }
                if timingTimes(from: line) != nil {
                    break
                }
                textLines.append(line)
                index += 1
            }
            let cueText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty {
                cues.append(SubtitleCue(start: timing.start, end: timing.end, text: cueText))
            }
        }
        return cues
    }

    private static func timingTimes(from line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }
        let leftTokens = parts[0].split(whereSeparator: { $0.isWhitespace })
        let rightTokens = parts[1].split(whereSeparator: { $0.isWhitespace })
        guard let startToken = leftTokens.last, let endToken = rightTokens.first else { return nil }
        guard let start = timeValue(String(startToken)), let end = timeValue(String(endToken)) else { return nil }
        return (start, end)
    }

    private static func timeValue(_ token: String) -> TimeInterval? {
        let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: " <>{}"))
        let components = clean.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "." }).map(String.init)
        guard components.count == 3 || components.count == 4 else { return nil }
        let numbers = components.compactMap(Double.init)
        guard numbers.count == components.count else { return nil }
        if numbers.count == 3 {
            return numbers[0] * 60 + numbers[1] + numbers[2] / 1000
        }
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2] + numbers[3] / 1000
    }

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for line in text.split(separator: "\n") {
            let string = String(line)
            guard string.hasPrefix("Dialogue:") else { continue }
            let fields = string.components(separatedBy: ",")
            guard fields.count >= 10,
                  let start = timeValue(fields[1]),
                  let end = timeValue(fields[2]) else { continue }
            let rawText = fields[9...].joined(separator: ",")
            let plain = stripASSTags(rawText)
            if !plain.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: plain))
            }
        }
        return cues
    }

    private static func stripASSTags(_ text: String) -> String {
        var result = ""
        var isInTag = false
        for character in text {
            if character == "{" {
                isInTag = true
            } else if character == "}" {
                isInTag = false
            } else if !isInTag {
                result.append(character)
            }
        }
        return result
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
