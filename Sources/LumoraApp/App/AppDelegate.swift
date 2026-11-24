import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        CrashReporter.install()
        _ = SettingsStore.shared
        _ = LibraryStore.shared
        installMainMenu()
        showMainWindow(nil)
        Task { @MainActor in
            await UpdateChecker.shared.checkIfNeeded(settings: SettingsStore.shared)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        showMainWindow(nil)
        mainWindowController?.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsStore.shared.save()
    }

    private func showMainWindow(_ sender: Any?) {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Lumora", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lumora", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lumora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenuItem()
        let fileSubmenu = NSMenu(title: "File")
        fileMenu.submenu = fileSubmenu
        fileSubmenu.addItem(withTitle: "New Player Window", action: #selector(newPlayerWindow(_:)), keyEquivalent: "n")
        fileSubmenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileSubmenu.addItem(withTitle: "Open Network Stream…", action: #selector(openNetworkStream(_:)), keyEquivalent: "u")
        fileSubmenu.addItem(.separator())
        fileSubmenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(fileMenu)

        let playbackMenu = NSMenuItem()
        let playbackSubmenu = NSMenu(title: "Playback")
        playbackMenu.submenu = playbackSubmenu
        playbackSubmenu.addItem(withTitle: "Play/Pause", action: #selector(PlayerViewController.togglePlayback(_:)), keyEquivalent: " ")
        playbackSubmenu.addItem(withTitle: "Stop", action: #selector(PlayerViewController.stopPlayback(_:)), keyEquivalent: ".")
        playbackSubmenu.addItem(.separator())
        playbackSubmenu.addItem(withTitle: "Seek Back 10s", action: #selector(PlayerViewController.seekBackward(_:)), keyEquivalent: "\u{1B}")
        playbackSubmenu.addItem(withTitle: "Seek Forward 10s", action: #selector(PlayerViewController.seekForward(_:)), keyEquivalent: "\u{1F}")
        playbackSubmenu.addItem(.separator())
        playbackSubmenu.addItem(withTitle: "Next Item", action: #selector(PlayerViewController.nextItem(_:)), keyEquivalent: ">")
        playbackSubmenu.addItem(withTitle: "Previous Item", action: #selector(PlayerViewController.previousItem(_:)), keyEquivalent: "<")
        playbackSubmenu.addItem(.separator())
        playbackSubmenu.addItem(withTitle: "Toggle Fullscreen", action: #selector(PlayerViewController.toggleFullscreen(_:)), keyEquivalent: "f")
        playbackSubmenu.addItem(withTitle: "Toggle Picture in Picture", action: #selector(PlayerViewController.togglePictureInPicture(_:)), keyEquivalent: "p")
        playbackSubmenu.addItem(withTitle: "Take Screenshot", action: #selector(PlayerViewController.takeScreenshot(_:)), keyEquivalent: "s")
        mainMenu.addItem(playbackMenu)

        let viewMenu = NSMenuItem()
        let viewSubmenu = NSMenu(title: "View")
        viewMenu.submenu = viewSubmenu
        viewSubmenu.addItem(withTitle: "Library…", action: #selector(showLibrary(_:)), keyEquivalent: "")
        viewSubmenu.addItem(withTitle: "Toggle Playlist", action: #selector(PlayerViewController.togglePlaylist(_:)), keyEquivalent: "l")
        viewSubmenu.addItem(withTitle: "Toggle Controls", action: #selector(PlayerViewController.toggleControlsVisibility(_:)), keyEquivalent: "c")
        viewSubmenu.addItem(withTitle: "Cycle Subtitles", action: #selector(PlayerViewController.cycleSubtitles(_:)), keyEquivalent: "t")
        viewSubmenu.addItem(withTitle: "Cycle Repeat Mode", action: #selector(PlayerViewController.cycleRepeatMode(_:)), keyEquivalent: "r")
        mainMenu.addItem(viewMenu)

        let toolsMenu = NSMenuItem()
        let toolsSubmenu = NSMenu(title: "Tools")
        toolsMenu.submenu = toolsSubmenu
        toolsSubmenu.addItem(withTitle: "Search Subtitles…", action: #selector(searchSubtitles(_:)), keyEquivalent: "")
        toolsSubmenu.addItem(withTitle: "Convert Media…", action: #selector(convertMedia(_:)), keyEquivalent: "")
        toolsSubmenu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        mainMenu.addItem(toolsMenu)

        let windowMenu = NSMenuItem()
        let windowSubmenu = NSMenu(title: "Window")
        windowMenu.submenu = windowSubmenu
        windowSubmenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowSubmenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowSubmenu

        let helpMenu = NSMenuItem()
        let helpSubmenu = NSMenu(title: "Help")
        helpMenu.submenu = helpSubmenu
        helpSubmenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "?")
        mainMenu.addItem(helpMenu)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout(_ sender: Any) {
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc private func showSettings(_ sender: Any) {
        SettingsWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newPlayerWindow(_ sender: Any) {
        let controller = MainWindowController()
        controller.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDocument(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .video, .data]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                self?.mainWindowController?.open(panel.urls)
            }
        }
    }

    @objc private func openNetworkStream(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "Open Network Stream"
        alert.informativeText = "Enter a URL. YouTube links use yt-dlp when available."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        mainWindowController?.open([url])
    }

    @objc private func showLibrary(_ sender: Any) {
        LibraryWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func searchSubtitles(_ sender: Any) {
        SubtitleSearchWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func convertMedia(_ sender: Any) {
        ConverterWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates(_ sender: Any) {
        Task { @MainActor in
            let info = await UpdateChecker.shared.check(settings: SettingsStore.shared, force: true)
            UpdateChecker.present(info)
        }
    }

    @objc private func showShortcuts(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        Space: play/pause
        Left/Right: seek 10s
        Option+Left/Right: seek 60s
        Up/Down: volume
        F: fullscreen
        P: picture in picture
        M: mute
        S: screenshot
        B: bookmark
        L: playlist
        T: cycle subtitles
        R: cycle repeat mode
        C: show/hide controls
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
