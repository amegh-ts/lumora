import Foundation

enum CrashReporter {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            AppPaths.ensureDirectories()
            let reason = exception.reason ?? "Unknown reason"
            let text = "\(exception.name.rawValue): \(reason)\n\(Thread.callStackSymbols.joined(separator: "\n"))\n"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = AppPaths.logs.appendingPathComponent("crash-\(formatter.string(from: Date())).log")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
