import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let engine = PlaybackEngine()
    private let playlist = PlaylistStore()
    private let settings = SettingsStore.shared
    private let library = LibraryStore.shared

    private lazy var playerViewController: PlayerViewController = {
        PlayerViewController(
            engine: engine,
            playlist: playlist,
            settings: settings,
            library: library
        )
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lumora"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        self.init(window: window)
        window.delegate = self
        contentViewController = playerViewController
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        showWindow(nil)
        Task { @MainActor in
            var resolved: [PlaybackItem] = []
            for url in urls {
                if YouTubeResolver.isYouTubeURL(url) {
                    if let stream = await YouTubeResolver.resolve(url, toolPath: settings.ytDLPPath) {
                        resolved.append(PlaybackItem(url: stream, title: url.absoluteString, kind: .network))
                    } else {
                        presentError(title: "YouTube resolution failed", message: "Install yt-dlp or set its path in Settings.")
                    }
                } else {
                    resolved.append(PlaybackItem(url: url))
                }
            }
            guard !resolved.isEmpty else { return }
            playlist.add(resolved, playFirst: playlist.items.isEmpty)
            if playlist.items.count == resolved.count {
                playCurrent()
            }
        }
    }

    func playCurrent() {
        guard let item = playlist.current else { return }
        let resumeTime = settings.rememberLastPosition ? library.record(for: item.url)?.resumeTime ?? 0 : 0
        engine.load(item, resumeTime: resumeTime)
        window?.title = item.title
    }

    func playNext(auto: Bool) {
        guard let item = playlist.next(auto: auto) else {
            engine.stop()
            window?.title = "Lumora"
            return
        }
        playCurrent()
        _ = item
    }

    func playPrevious() {
        guard playlist.previous() != nil else { return }
        playCurrent()
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
