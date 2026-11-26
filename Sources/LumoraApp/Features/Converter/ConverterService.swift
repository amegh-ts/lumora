import Foundation

enum ConverterService {
    static let presets: [ConvertPreset] = [
        ConvertPreset(id: "h264", title: "H.264 / AAC MP4", arguments: ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k"]),
        ConvertPreset(
            id: "hevc", title: "HEVC / AAC MP4",
            arguments: ["-c:v", "libx265", "-preset", "medium", "-crf", "22", "-c:a", "aac", "-b:a", "192k", "-tag:v", "hvc1"]),
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

    /// The running ffmpeg, so it can be cancelled and is stopped when Lumora quits.
    nonisolated(unsafe) private(set) static var activeProcess: Process?
    private static let processLock = NSLock()

    static func cancelActive() {
        let process = processLock.withLock { activeProcess }
        process?.terminate()
    }

    /// How far a conversion has got: fraction (0…1) once the length is known, encoding speed
    /// (1 = real time) and seconds left.
    struct Progress: Sendable {
        var fraction: Double?
        var speed: Double?
        var secondsLeft: Double?
    }

    /// `overwrite` is true only when the user confirmed "Replace" in the save panel. `progress`
    /// is called on the main thread about twice a second.
    static func convert(
        input: URL, output: URL, preset: ConvertPreset, ffmpegPath: String, overwrite: Bool = false,
        progress: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async -> String? {
        if input.standardizedFileURL.resolvingSymlinksInPath() == output.standardizedFileURL.resolvingSymlinksInPath() {
            return "The output file can't be the same as the source file."
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath.isEmpty ? "/usr/bin/env" : ffmpegPath)
            // -progress writes key=value lines (out_time_us, speed) to stdout; -nostats keeps
            // stderr for the header (Duration) and errors.
            let arguments = [overwrite ? "-y" : "-n", "-nostats", "-progress", "pipe:1", "-i", input.path] + preset.arguments + [output.path]
            process.arguments = ffmpegPath.isEmpty ? ["ffmpeg"] + arguments : arguments
            let errorPipe = Pipe()
            let outputPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = outputPipe
            let state = ConversionState()
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                state.appendError(handle.availableData)
            }
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                guard let update = state.appendProgress(handle.availableData), let progress else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { progress(update) } }
            }
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            processLock.withLock { activeProcess = process }
            defer { processLock.withLock { activeProcess = nil } }
            process.waitUntilExit()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputPipe.fileHandleForReading.readabilityHandler = nil
            state.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())
            if process.terminationStatus == 0 {
                return nil
            }
            if process.terminationReason == .uncaughtSignal {
                try? FileManager.default.removeItem(at: output)
                return "Cancelled."
            }
            let message = state.errorText
            if !message.isEmpty {
                return String(message.split(separator: "\n").suffix(8).joined(separator: "\n"))
            }
            return "ffmpeg exited with status \(process.terminationStatus)"
        }.value
    }
}

/// Collects ffmpeg's output on its pipe threads: the error text, the input's length from the
/// header, and the latest progress block.
private final class ConversionState: @unchecked Sendable {
    private let lock = NSLock()
    private var error = Data()
    private var pending = ""
    private var duration: Double?
    private var outTime: Double = 0
    private var speed: Double?

    var errorText: String {
        lock.withLock { String(data: error, encoding: .utf8) ?? "" }
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            error.append(data)
            if duration == nil, error.count < 1_000_000, let text = String(data: error, encoding: .utf8),
                let range = text.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression)
            {
                let parts = text[range].dropFirst("Duration: ".count).split(separator: ":").compactMap { Double($0) }
                if parts.count == 3 {
                    duration = parts[0] * 3600 + parts[1] * 60 + parts[2]
                }
            }
        }
    }

    /// Returns a progress update when a full block (ending in progress=…) has arrived.
    func appendProgress(_ data: Data) -> ConverterService.Progress? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        return lock.withLock {
            pending += text
            var update: ConverterService.Progress?
            while let newline = pending.firstIndex(of: "\n") {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "out_time_us", "out_time_ms":
                    // Both are microseconds (out_time_ms is misnamed in ffmpeg).
                    if let value = Double(pair[1]), value >= 0 { outTime = value / 1_000_000 }
                case "speed":
                    speed = Double(pair[1].replacingOccurrences(of: "x", with: ""))
                case "progress":
                    let fraction = duration.map { $0 > 0 ? min(max(outTime / $0, 0), 1) : 0 }
                    var left: Double?
                    if let duration, let speed, speed > 0 {
                        left = max(0, duration - outTime) / speed
                    }
                    update = ConverterService.Progress(fraction: pair[1] == "end" ? 1 : fraction, speed: speed, secondsLeft: left)
                default:
                    break
                }
            }
            return update
        }
    }
}
