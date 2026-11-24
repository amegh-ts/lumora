import Foundation

enum ConverterService {
    static let presets: [ConvertPreset] = [
        ConvertPreset(id: "h264", title: "H.264 / AAC MP4", arguments: ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k"]),
        ConvertPreset(id: "hevc", title: "HEVC / AAC MP4", arguments: ["-c:v", "libx265", "-preset", "medium", "-crf", "22", "-c:a", "aac", "-b:a", "192k", "-tag:v", "hvc1"]),
        ConvertPreset(id: "av1", title: "AV1 / Opus WebM", arguments: ["-c:v", "libaom-av1", "-crf", "30", "-b:v", "0", "-c:a", "libopus", "-b:a", "128k"]),
        ConvertPreset(id: "audio-mp3", title: "Audio MP3", arguments: ["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]),
        ConvertPreset(id: "audio-aac", title: "Audio AAC M4A", arguments: ["-vn", "-c:a", "aac", "-b:a", "192k"])
    ]

    static func outputURL(for input: URL, preset: ConvertPreset) -> URL {
        let ext: String
        switch preset.id {
        case "av1": ext = "webm"
        case "audio-mp3": ext = "mp3"
        case "audio-aac": ext = "m4a"
        default: ext = "mp4"
        }
        let directory = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base) (converted)").appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (converted \(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    static func convert(input: URL, output: URL, preset: ConvertPreset, ffmpegPath: String) async -> String? {
        if input.standardizedFileURL.resolvingSymlinksInPath() == output.standardizedFileURL.resolvingSymlinksInPath() {
            return "The output file can't be the same as the source file."
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath.isEmpty ? "/usr/bin/env" : ffmpegPath)
            if ffmpegPath.isEmpty {
                process.arguments = ["ffmpeg", "-n", "-i", input.path] + preset.arguments + [output.path]
            } else {
                process.arguments = ["-n", "-i", input.path] + preset.arguments + [output.path]
            }
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return nil
            }
            if let message = String(data: errorData, encoding: .utf8), !message.isEmpty {
                return String(message.split(separator: "\n").suffix(8).joined(separator: "\n"))
            }
            return "ffmpeg exited with status \(process.terminationStatus)"
        }.value
    }
}
