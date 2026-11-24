import Foundation

enum AppPaths {
    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return url.appendingPathComponent("Lumora", isDirectory: true)
    }

    static var settingsFile: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    static var libraryFile: URL {
        applicationSupport.appendingPathComponent("library.json")
    }

    static var thumbnailCache: URL {
        applicationSupport.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    static var subtitleCache: URL {
        applicationSupport.appendingPathComponent("Subtitles", isDirectory: true)
    }

    static var screenshots: URL {
        applicationSupport.appendingPathComponent("Screenshots", isDirectory: true)
    }

    static var logs: URL {
        applicationSupport.appendingPathComponent("Logs", isDirectory: true)
    }

    static func ensureDirectories() {
        let fileManager = FileManager.default
        let directories = [
            applicationSupport,
            thumbnailCache,
            subtitleCache,
            screenshots,
            logs
        ]
        for directory in directories {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum TimeFormatter {
    static func string(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else {
            return "0:00"
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
