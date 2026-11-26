import AppKit

/// Crash reports without a crash library or a server.
///
/// macOS already writes a full report (`.ips`) for every crash, Swift traps and signals included.
/// On the next launch Lumora finds the newest one it hasn't handled, shows a short summary with
/// file names, titles and links removed, and, only if the user agrees, opens it as a pre-filled
/// GitHub issue they can read before submitting.
enum CrashReporter {
    static let issuesURL = "https://github.com/amegh-ts/lumora/issues/new"
    private static let lastHandledKey = "lumora.crash.lastHandled"
    static let enabledKey = "lumora.crash.offerReports"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Objective-C exceptions also end in a macOS report; this only adds the exception text,
    /// which that report doesn't always include.
    static func install() {
        SessionLog.keepPreviousRun()
        NSSetUncaughtExceptionHandler { exception in
            let line = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")"
            SessionLog.record(line, synchronously: true)
        }
    }

    // MARK: Finding the report

    struct Report {
        var title: String
        var body: String
        var fileURL: URL
    }

    /// The newest unhandled Lumora crash, or nil. Marks it handled so the user is asked once.
    @MainActor
    static func pendingReport() -> Report? {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        // First launch with crash reporting: older crashes are history, not something to ask about.
        guard let lastHandled = defaults.object(forKey: lastHandledKey) as? Double else {
            defaults.set(now, forKey: lastHandledKey)
            return nil
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files.compactMap { url -> (URL, Double)? in
            guard url.lastPathComponent.hasPrefix("Lumora"), url.pathExtension == "ips",
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970,
                date > lastHandled
            else { return nil }
            return (url, date)
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        defaults.set(newest.1, forKey: lastHandledKey)
        return report(from: newest.0)
    }

    /// Builds the summary from a macOS crash report (a JSON header line, then a JSON body).
    @MainActor
    static func report(from url: URL) -> Report? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let split = text.firstIndex(of: "\n"),
            let header = try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8)) as? [String: Any],
            let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8)) as? [String: Any]
        else { return nil }
        // Only this app's crashes (another app or tool could also be called "Lumora").
        let bundle = Bundle.main.bundleIdentifier ?? "com.lumora.player"
        let bundleInfo = body["bundleInfo"] as? [String: Any]
        let identifier = bundleInfo?["CFBundleIdentifier"] as? String ?? body["codeSigningID"] as? String ?? ""
        #if !DEBUG
            guard identifier == bundle else { return nil }
        #endif

        let exception = body["exception"] as? [String: Any]
        let kind = [exception?["type"] as? String, exception?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
        var reasons: [String] = []
        if let asi = body["asi"] as? [String: [String]] {
            reasons = asi.values.flatMap { $0 }
        }
        if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] as? String {
            reasons.append(indicator)
        }

        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        let frames = (threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] : nil) ?? []
        let lines = frames.prefix(30).enumerated().map { index, frame -> String in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            var symbol = frame["symbol"] as? String ?? "?"
            if let file = frame["sourceFile"] as? String, let line = frame["sourceLine"] as? Int {
                symbol += "  (\(file):\(line))"
            }
            return String(format: "%2d  %@  %@", index, image.padding(toLength: 18, withPad: " ", startingAt: 0), symbol)
        }
        // The title names Lumora's own frame if there is one, else the first frame outside the
        // generic system layers (AppKit layout, libsystem…), which usually says what went wrong.
        let generic: Set<String> = [
            "libsystem_kernel.dylib", "libsystem_c.dylib", "libsystem_pthread.dylib", "libdyld.dylib", "dyld", "libc++abi.dylib",
            "libobjc.A.dylib", "libswiftCore.dylib", "libswift_Concurrency.dylib", "AppKit", "Foundation", "CoreFoundation", "QuartzCore", "HIToolbox",
            "libdispatch.dylib"
        ]
        let named = frames.compactMap { frame -> (image: String, symbol: String)? in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
            guard let symbol = frame["symbol"] as? String, symbol != "?" else { return nil }
            return (image, symbol)
        }
        let headline =
            named.prefix(12).first { ($0.image == "Lumora" || $0.image == "LumoraApp") && $0.symbol != "main" }?.symbol
            ?? named.first { !generic.contains($0.image) }?.symbol
            ?? named.first?.symbol
            ?? kind

        let info = Bundle.main.infoDictionary ?? [:]
        let version = header["app_version"] as? String
        let build = header["build_version"] as? String
        let appVersion = (version?.isEmpty == false ? version : info["CFBundleShortVersionString"] as? String) ?? "dev"
        let appBuild = (build?.isEmpty == false ? build : info["CFBundleVersion"] as? String) ?? "-"
        let renderer = SettingsStore.shared.renderer.title
        // Only messages from shortly before the crash; the log may belong to a later, unrelated run.
        let crashTime = (header["timestamp"] as? String).flatMap(Self.parseCrashTime)
        let mpvErrors = SessionLog.recentLines().filter { line in
            guard let crashTime, let stamp = line.split(separator: " ").first,
                let time = ISO8601DateFormatter().date(from: String(stamp))
            else { return false }
            return time <= crashTime.addingTimeInterval(5) && time >= crashTime.addingTimeInterval(-600)
        }

        var markdown = """
            **Lumora** \(appVersion) (build \(appBuild))
            **macOS** \(header["os_version"] as? String ?? "?")
            **Mac** \(body["modelCode"] as? String ?? "?") · \(body["cpuType"] as? String ?? "")
            **Renderer** \(renderer)
            **Crash** \(kind)

            """
        if !reasons.isEmpty {
            markdown += "**Reason**\n```\n\(reasons.joined(separator: "\n"))\n```\n"
        }
        markdown += "**Crashed thread**\n```\n\(lines.joined(separator: "\n"))\n```\n"
        if !mpvErrors.isEmpty {
            markdown += "**Last player messages**\n```\n\(mpvErrors.suffix(12).joined(separator: "\n"))\n```\n"
        }
        markdown += "\n**What were you doing when it crashed?**\n\n"
        markdown += "<!-- Sent from Lumora's crash dialog. File names, titles and links were removed. Incident \(header["incident_id"] as? String ?? "?") -->\n"
        return Report(title: "Crash: \(scrub(headline))", body: scrub(markdown), fileURL: url)
    }

    /// "2026-11-25 09:17:17.00 +0530" from a macOS crash report header.
    static func parseCrashTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Removes anything that could identify the user or what they watch: home folders, file
    /// names and paths, and links.
    static func scrub(_ text: String) -> String {
        var result = text
        let home = NSHomeDirectory()
        result = result.replacingOccurrences(of: home, with: "~")
        let patterns: [(String, String)] = [
            (#"https?://[^\s)\]"']+"#, "<link>"),
            (#"[a-z]+://[^\s)\]"']+"#, "<link>"),
            (#"/Users/[^/\s]+"#, "~"),
            // File paths, including names with spaces: from the folder start up to the extension.
            (#"(?:~|/(?:Volumes|private|tmp|var|Applications|Library))/[^\n"]*?\.[A-Za-z0-9]{2,5}\b"#, "<file>"),
            // Anything else still under the home folder.
            (#"~/[^\s"]*"#, "<path>"),
            (#"“[^”]*”"#, "“…”")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    // MARK: Asking

    @MainActor
    static func offerToSendPendingReport() {
        guard isEnabled, let report = pendingReport() else { return }
        present(report)
    }

    @MainActor
    static func present(_ report: Report) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Lumora quit unexpectedly the last time it was used"
        alert.informativeText =
            "Sending a report helps fix it. It opens as a GitHub issue that you can read before submitting. It has the Lumora and macOS versions, your Mac model and where Lumora crashed. File names, titles and links are removed."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        text.string = report.body
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.drawsBackground = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Send Report…")
        alert.addButton(withTitle: "Don't Send")
        alert.addButton(withTitle: "Copy Report")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask about crashes again"
        AppDelegate.activateApp()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            isEnabled = false
        }
        switch response {
        case .alertFirstButtonReturn:
            if let url = issueURL(for: report) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("# \(report.title)\n\n\(report.body)", forType: .string)
        default:
            break
        }
    }

    /// GitHub's new-issue page, pre-filled. Long stacks are shortened to keep the link working.
    @MainActor
    static func issueURL(for report: Report) -> URL? {
        var body = report.body
        func url(_ body: String) -> URL? {
            var components = URLComponents(string: issuesURL)
            components?.queryItems = [
                URLQueryItem(name: "title", value: report.title),
                URLQueryItem(name: "body", value: body),
                URLQueryItem(name: "labels", value: "crash")
            ]
            return components?.url
        }
        while let candidate = url(body), candidate.absoluteString.count > 7500, body.count > 400 {
            body = String(body.prefix(body.count * 3 / 4)) + "\n…(shortened; use Copy Report for the rest)\n```"
        }
        return url(body)
    }
}

/// The last player error messages, kept on disk so they survive a crash.
enum SessionLog {
    private static let queue = DispatchQueue(label: "com.lumora.session-log", qos: .utility)
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var previous: [String] = []
    private static var file: URL { AppPaths.logs.appendingPathComponent("recent-errors.log") }

    static func record(_ line: String, synchronously: Bool = false) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line.trimmingCharacters(in: .whitespacesAndNewlines))"
        let write = {
            lines.append(entry)
            if lines.count > 40 {
                lines.removeFirst(lines.count - 40)
            }
            AppPaths.ensureDirectories()
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        synchronously ? queue.sync(execute: write) : queue.async(execute: write)
    }

    /// Reads what the previous run left behind, before this run writes anything.
    static func keepPreviousRun() {
        queue.sync {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            previous = text.split(separator: "\n").map(String.init)
        }
    }

    /// The previous run's last messages (the run that may have crashed).
    static func recentLines() -> [String] {
        queue.sync { previous }
    }
}
