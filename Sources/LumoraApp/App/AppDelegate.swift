import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var quitObserver: NSObjectProtocol?

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
        #if DEBUG
        FileHandle.standardError.write("[debug] open urls=\(urls.map(\.lastPathComponent)) controllers=\(controllers.count) key=\(NSApp.keyWindow != nil)\n".data(using: .utf8)!)
        #endif
        activeController().open(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers {
            controller.close()
        }
        SettingsStore.shared.save()
        guard PlaybackEngine.pendingShutdowns > 0 else { return .terminateNow }
        quitObserver = NotificationCenter.default.addObserver(forName: .lumoraEnginesStopped, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishQuit() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.finishQuit()
        }
        return .terminateLater
    }

    private func finishQuit() {
        guard let quitObserver else { return }
        NotificationCenter.default.removeObserver(quitObserver)
        self.quitObserver = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func newController() -> MainWindowController {
        let controller = MainWindowController()
        if let previous = controllers.last?.window, let window = controller.window {
            let topLeft = NSPoint(x: previous.frame.minX + 28, y: previous.frame.maxY - 28)
            window.setFrameTopLeftPoint(topLeft)
            if let screen = previous.screen ?? NSScreen.main {
                window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
            }
        }
        #if DEBUG
        FileHandle.standardError.write("[debug] new player window (total \(controllers.count + 1))\n".data(using: .utf8)!)
        #endif
        controller.onClose = { [weak self] closed in
            #if DEBUG
            FileHandle.standardError.write("[debug] player window closed\n".data(using: .utf8)!)
            #endif
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
        NSApp.mainMenu = MainMenuBuilder.build { [weak self] url in
            self?.activeController().open([url])
        }
    }

    @objc func showAudioSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "Audio")
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showVideoSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "Video")
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSubtitleSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "Subtitles")
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openProjectPage(_ sender: Any?) {
        if let url = URL(string: "https://github.com/amegh-ts/lumora") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reportIssue(_ sender: Any?) {
        if let url = URL(string: "https://github.com/amegh-ts/lumora/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newPlayerWindow(_ sender: Any?) {
        _ = newController()
    }

    @objc func openDocument(_ sender: Any?) {
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

    @objc func openNetworkStream(_ sender: Any?) {
        let controller = activeController()
        controller.showWindow(nil)
        controller.promptForURL()
    }

    @objc func showLibrary(_ sender: Any?) {
        LibraryWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func searchSubtitles(_ sender: Any?) {
        SubtitleSearchWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func convertMedia(_ sender: Any?) {
        ConverterWindowController.shared.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    @objc func showShortcuts(_ sender: Any?) {
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
        Z / X — subtitles earlier / later
        M — mute;  S — screenshot;  P — playlist
        ⌘← / ⌘→ — previous / next item
        ⌥⌘M — mini player;  ⌥⌘T — keep on top
        Scroll — volume (vertical), seek (horizontal)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
