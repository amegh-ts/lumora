import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    nonisolated static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts",
        "3gp", "ogv", "vob", "rm", "rmvb", "asf", "divx", "f4v", "hevc", "y4m",
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "alac", "aiff", "aif", "ape", "dts", "ac3", "mka",
        "m3u", "m3u8", "pls"
    ]

    var onClose: ((MainWindowController) -> Void)?

    /// Only the first player window can own this name; extra windows cascade from the existing one.
    static let frameAutosaveName = "LumoraPlayerWindow"

    private static var debugRenderer: VideoRenderer? {
        #if DEBUG
            return ProcessInfo.processInfo.environment["LUMORA_RENDERER"].flatMap(VideoRenderer.init(rawValue:))
        #else
            return nil
        #endif
    }

    private let engine: PlaybackEngine
    private let playlist = PlaylistStore()
    private let settings = SettingsStore.shared
    private let library = LibraryStore.shared
    private let playerViewController: PlayerViewController

    init() {
        engine = PlaybackEngine(
            ytdlPath: SettingsStore.shared.ytDLPPath,
            hardwareDecoding: SettingsStore.shared.hardwareDecoding,
            renderer: Self.debugRenderer ?? SettingsStore.shared.renderer,
            streamHeightCap: SettingsStore.shared.streamQuality.maxHeight
        )
        playerViewController = PlayerViewController(
            engine: engine,
            playlist: playlist,
            settings: SettingsStore.shared,
            library: LibraryStore.shared
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumora"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 420, height: 260)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        contentViewController = playerViewController
        window.setContentSize(NSSize(width: 1040, height: 620))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        playerViewController.applyInitialVolume()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        if DebugMode.background {
            window?.orderBack(nil)
            return
        }
        super.showWindow(sender)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        playerViewController.leaveMiniPlayerIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        playerViewController.tearDown()
        onClose?(self)
    }

    /// Single entry point for Finder, Dock, menu, drag-and-drop and URL opens.
    /// Subtitle files attach to the video being played (or the one opened alongside them).
    func open(_ urls: [URL]) {
        let subtitles = urls.filter(SubtitleService.isSubtitleFile)
        let media = urls.filter { !SubtitleService.isSubtitleFile($0) }
        showWindow(nil)
        if !subtitles.isEmpty {
            playerViewController.addSubtitles(subtitles, forNextFile: !media.isEmpty)
        }
        guard !media.isEmpty else { return }
        if media.count == 1, PlaylistImporter.isYouTubePlaylist(media[0]) {
            openYouTubePlaylist(media[0])
            return
        }
        if media.count == 1, !media[0].isFileURL, ["m3u", "m3u8"].contains(media[0].pathExtension.lowercased()) {
            openPossibleChannelList(media[0])
            return
        }
        // Folders can hold thousands of files (or sit on a slow network share): list them off the main thread.
        Task { [weak self] in
            let expanded = await Self.expandInBackground(media)
            guard let self else { return }
            if expanded.isEmpty {
                self.reportMissing(media)
                return
            }
            let missing = media.filter { $0.isFileURL && !FileManager.default.fileExists(atPath: $0.path) }
            if !missing.isEmpty {
                self.reportMissing(missing)
            }
            // Reopening something already in the playlist selects it instead of adding a duplicate.
            if expanded.count == 1, let existing = self.playlist.index(of: expanded[0].url) {
                self.playlist.select(at: existing)
                self.playCurrent()
                return
            }
            let firstNewIndex = self.playlist.items.count
            self.playlist.add(expanded)
            self.playlist.select(at: firstNewIndex)
            self.playCurrent()
        }
    }

    /// Loads every video of a YouTube playlist as its own item, starting at the linked video.
    /// Falls back to playing the link directly if yt-dlp can't list it.
    private func openYouTubePlaylist(_ url: URL) {
        playerViewController.osd.show("Loading playlist…", symbol: "list.bullet.rectangle", duration: 3)
        let tool = Self.toolPath(settings.ytDLPPath, name: "yt-dlp")
        Task { [weak self] in
            let result = await PlaylistImporter.youTubeEntries(for: url, ytdlPath: tool)
            guard let self else { return }
            guard let result else {
                self.playlist.add([PlaybackItem(url: url)])
                self.playlist.select(at: self.playlist.items.count - 1)
                self.playCurrent()
                return
            }
            let firstNewIndex = self.playlist.items.count
            self.playlist.add(result.entries.map { PlaybackItem(url: $0.url, title: $0.title) })
            self.playlist.select(at: firstNewIndex + result.start)
            self.playCurrent()
            self.playerViewController.osd.show("\(result.entries.count) videos added", symbol: "list.bullet.rectangle")
        }
    }

    /// The configured tool, or the usual Homebrew locations when that path doesn't exist.
    private static func toolPath(_ configured: String, name: String) -> String {
        let candidates = [configured, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? configured
    }

    private static func expandInBackground(_ urls: [URL]) async -> [PlaybackItem] {
        await Task.detached(priority: .userInitiated) {
            MainWindowController.expandFiles(urls)
        }.value
    }

    private func showInvalidURL(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.isEmpty ? "Enter a link to play" : "That doesn't look like a playable link"
        alert.informativeText = "Use a web or stream address that starts with https://, http://, rtsp:// or similar."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.promptForURL() }
        }
    }

    /// Recent items, Library and Finder can point at files that were moved or deleted.
    private func reportMissing(_ urls: [URL]) {
        guard let window, let first = urls.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            urls.count == 1
            ? "“\(first.deletingPathExtension().lastPathComponent)” couldn't be found"
            : "\(urls.count) items couldn't be found"
        alert.informativeText = "It may have been moved, renamed or deleted, or its drive isn't connected."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Remove from Recents")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            MainActor.assumeIsolated {
                urls.forEach { LibraryStore.shared.remove(url: $0) }
            }
        }
    }

    func enqueue(_ urls: [URL]) {
        let items = Self.expandFiles(urls)
        guard !items.isEmpty else { return }
        let wasEmpty = playlist.items.isEmpty
        playlist.add(items)
        if wasEmpty {
            playCurrent()
        }
    }

    func promptForURL() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText =
            "Paste a link to a video, a stream (HLS, RTSP, HTTP) or a page on YouTube and other sites. YouTube playlist links add every video."
        alert.icon = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        field.placeholderString = "https://"
        field.setAccessibilityLabel("Link")
        // A link already on the clipboard is filled in and selected, ready to replace.
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            copied.count < 2048, Self.normalizedLink(copied) != nil
        {
            field.stringValue = copied
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            MainActor.assumeIsolated {
                guard let url = Self.normalizedLink(text) else {
                    self?.showInvalidURL(text)
                    return
                }
                self?.open([url])
            }
        }
        field.currentEditor()?.selectAll(nil)
    }

    /// A playable link from typed text: adds https:// to "youtube.com/…"-style input and accepts
    /// only the network schemes Lumora plays.
    static func normalizedLink(_ text: String) -> URL? {
        var candidate = text
        if !candidate.contains("://"), candidate.contains("."), !candidate.contains(" ") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false,
            PlaylistImporter.allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }

    func playChannels(_ items: [PlaybackItem], startAt index: Int) {
        guard items.indices.contains(index) else { return }
        showWindow(nil)
        playerViewController.saveProgress(force: true)
        playlist.clear()
        playlist.add(items)
        playlist.select(at: index)
        playCurrent()
    }

    /// A single .m3u link: a channel list goes to Channels, a stream playlist plays here.
    private func openPossibleChannelList(_ url: URL) {
        playerViewController.osd.show("Reading the list…", symbol: "list.bullet.rectangle", duration: 3)
        Task { [weak self] in
            let result = await ChannelStore.fetch(url)
            guard let self else { return }
            if case .success(let channels) = result, channels.count > 1 {
                DebugTimeline.log("channel list \(channels.count) channels")
                let id = ChannelStore.shared.addSource(url: url, channels: channels)
                ChannelsWindowController.shared.show(source: id)
                AppDelegate.activateApp()
                return
            }
            self.playlist.add([PlaybackItem(url: url)])
            self.playlist.select(at: self.playlist.items.count - 1)
            self.playCurrent()
        }
    }

    func playCurrent() {
        guard let item = playlist.current else { return }
        playerViewController.saveProgress(force: true)
        let record = library.record(for: item.url)
        var resume: TimeInterval = 0
        if settings.rememberLastPosition, let record, !record.watched {
            resume = record.resumeTime
        }
        engine.load(item, resumeTime: resume)
    }

    func playNext(auto: Bool) {
        guard playlist.next(auto: auto) != nil else {
            if auto {
                engine.pause()
            }
            return
        }
        playCurrent()
    }

    func playPrevious() {
        if engine.currentTime > 5 {
            engine.seek(to: 0)
            return
        }
        guard playlist.previous() != nil else { return }
        playCurrent()
    }

    /// Files, folders (sorted, recursive) and playlist files become playlist items.
    nonisolated static func expandFiles(_ urls: [URL]) -> [PlaybackItem] {
        var result: [PlaybackItem] = []
        for url in urls {
            guard url.isFileURL else {
                result.append(PlaybackItem(url: url))
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let file = enumerator?.nextObject() as? URL {
                    // A folder's own media already covers what any playlist file in it lists.
                    if Self.isMedia(file), !PlaylistImporter.fileExtensions.contains(file.pathExtension.lowercased()) {
                        found.append(file)
                    }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result.append(contentsOf: found.map { PlaybackItem(url: $0) })
            } else if let entries = PlaylistImporter.entries(inFile: url) {
                result.append(contentsOf: entries.map { PlaybackItem(url: $0.url, title: $0.title) })
            } else if Self.isMedia(url) || !SubtitleService.isSubtitleFile(url) {
                result.append(PlaybackItem(url: url))
            }
        }
        return result
    }

    nonisolated private static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) {
            return true
        }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}
