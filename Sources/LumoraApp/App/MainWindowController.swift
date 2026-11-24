import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let mediaExtensions: Set<String> = [
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
            renderer: Self.debugRenderer ?? SettingsStore.shared.renderer
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
        let items = expand(media).map { PlaybackItem(url: $0) }
        guard !items.isEmpty else { return }
        let firstNewIndex = playlist.items.count
        playlist.add(items)
        playlist.select(at: firstNewIndex)
        playCurrent()
    }

    func enqueue(_ urls: [URL]) {
        let items = expand(urls).map { PlaybackItem(url: $0) }
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
        alert.informativeText = "Paste a link to a video, stream (HLS, RTSP, HTTP) or a YouTube page."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            MainActor.assumeIsolated {
                guard let url = URL(string: text), url.scheme != nil else { return }
                self?.open([url])
            }
        }
    }

    func playCurrent() {
        guard let item = playlist.current else { return }
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

    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard url.isFileURL else {
                result.append(url)
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
                    if isMedia(file) {
                        found.append(file)
                    }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                result.append(contentsOf: found)
            } else if isMedia(url) || !SubtitleService.isSubtitleFile(url) {
                result.append(url)
            }
        }
        return result
    }

    private func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) {
            return true
        }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audiovisualContent)
    }
}
