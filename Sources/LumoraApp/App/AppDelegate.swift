import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        CrashReporter.install()
        _ = SettingsStore.shared
        _ = LibraryStore.shared
        installMainMenu()
        if controllers.isEmpty {
            _ = newController()
        }
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        DebugHarness.run { [weak self] urls in self?.activeController().open(urls) }
        #endif
        Updater.shared.start(settings: SettingsStore.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            activeController().showWindow(nil)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        activeController().open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in controllers {
            controller.close()
        }
        SettingsStore.shared.save()
    }

    private func newController() -> MainWindowController {
        let controller = MainWindowController()
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func activeController() -> MainWindowController {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController {
            return key
        }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController {
            return main
        }
        if let existing = controllers.last {
            existing.showWindow(nil)
            return existing
        }
        return newController()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = submenu(in: mainMenu, title: "Lumora")
        appMenu.addItem(withTitle: "About Lumora", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lumora", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lumora", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = submenu(in: mainMenu, title: "File")
        fileMenu.addItem(withTitle: "New Player Window", action: #selector(newPlayerWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Open URL…", action: #selector(openNetworkStream(_:)), keyEquivalent: "u")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = submenu(in: mainMenu, title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        item(editMenu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let playbackMenu = submenu(in: mainMenu, title: "Playback")
        playbackMenu.addItem(withTitle: "Play / Pause    Space", action: #selector(PlayerViewController.togglePlayback(_:)), keyEquivalent: "")
        playbackMenu.addItem(withTitle: "Stop", action: #selector(PlayerViewController.stopPlayback(_:)), keyEquivalent: ".")
        playbackMenu.addItem(.separator())
        item(playbackMenu, "Next Item", #selector(PlayerViewController.nextItem(_:)), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command])
        item(playbackMenu, "Previous Item", #selector(PlayerViewController.previousItem(_:)), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command])
        playbackMenu.addItem(withTitle: "Cycle Repeat Mode", action: #selector(PlayerViewController.cycleRepeatMode(_:)), keyEquivalent: "")
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(withTitle: "A-B Loop    L", action: #selector(PlayerViewController.cycleABLoop(_:)), keyEquivalent: "")
        playbackMenu.addItem(withTitle: "Next Audio Track    A", action: #selector(PlayerViewController.cycleAudio(_:)), keyEquivalent: "")
        playbackMenu.addItem(withTitle: "Next Subtitle    T", action: #selector(PlayerViewController.cycleSubtitles(_:)), keyEquivalent: "")
        playbackMenu.addItem(.separator())
        item(playbackMenu, "Take Screenshot", #selector(PlayerViewController.takeScreenshot(_:)), "s", [.command, .shift])

        let viewMenu = submenu(in: mainMenu, title: "View")
        item(viewMenu, "Enter Full Screen", #selector(PlayerViewController.toggleFullscreen(_:)), "f", [.command, .control])
        item(viewMenu, "Mini Player", #selector(PlayerViewController.toggleMiniPlayer(_:)), "m", [.command, .option])
        item(viewMenu, "Keep on Top", #selector(PlayerViewController.toggleKeepOnTop(_:)), "t", [.command, .option])
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Show Playlist", action: #selector(PlayerViewController.togglePlaylist(_:)), keyEquivalent: "l")
        item(viewMenu, "Library", #selector(showLibrary(_:)), "l", [.command, .shift])

        let toolsMenu = submenu(in: mainMenu, title: "Tools")
        toolsMenu.addItem(withTitle: "Search Subtitles Online…", action: #selector(searchSubtitles(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: "Convert Media…", action: #selector(convertMedia(_:)), keyEquivalent: "")

        let windowMenu = submenu(in: mainMenu, title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        let helpMenu = submenu(in: mainMenu, title: "Help")
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "/")
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    @objc private func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newPlayerWindow(_ sender: Any?) {
        _ = newController()
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                self?.activeController().open(urls)
            }
        }
    }

    @objc private func openNetworkStream(_ sender: Any?) {
        let controller = activeController()
        controller.showWindow(nil)
        controller.promptForURL()
    }

    @objc private func showLibrary(_ sender: Any?) {
        LibraryWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func searchSubtitles(_ sender: Any?) {
        SubtitleSearchWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func convertMedia(_ sender: Any?) {
        ConverterWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    @objc private func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        Space or K — play / pause
        ← / → — seek 10 s  (⇧ 3 s, ⌥ 60 s)
        ↑ / ↓ — volume
        F or double-click — full screen;  Esc — exit
        [ / ] — slower / faster;  = — normal speed
        , / . — previous / next frame
        L — A-B loop;  B — bookmark
        A — next audio track;  T — next subtitle
        M — mute;  S — screenshot;  P — playlist
        ⌘← / ⌘→ — previous / next item
        ⌥⌘M — mini player;  ⌥⌘T — keep on top
        Scroll — volume (vertical), seek (horizontal)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
