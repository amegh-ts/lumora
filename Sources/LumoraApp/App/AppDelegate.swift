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
        Self.activateApp()
        #if DEBUG
            DebugHarness.run { [weak self] urls in self?.activeController().open(urls) }
        #endif
        Updater.shared.start(settings: SettingsStore.shared)
        // After the window is up, offer to send a report if Lumora crashed last time.
        if !DebugMode.background {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CrashReporter.offerToSendPendingReport()
            }
        }
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
            FileHandle.standardError.write(
                "[debug] open urls=\(urls.map(\.lastPathComponent)) controllers=\(controllers.count) key=\(NSApp.keyWindow != nil)\n".data(using: .utf8)!)
        #endif
        activeController().open(urls)
        Self.activateApp()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers {
            controller.close()
        }
        SettingsStore.shared.save()
        LibraryStore.shared.flush()
        ConverterService.cancelActive()
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

    /// Brings Lumora forward, except in DEBUG background test runs (LUMORA_BACKGROUND=1).
    static func activateApp() {
        if DebugMode.background { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Window › Live TV when no player window has focus: opens the panel in the active one.
    @objc func showChannels(_ sender: Any?) {
        activeController().showLiveTV(addList: false)
        Self.activateApp()
    }

    @objc func addChannelList(_ sender: Any?) {
        activeController().showLiveTV(addList: true)
        Self.activateApp()
    }

    func openInActivePlayer(_ urls: [URL]) {
        activeController().open(urls)
        Self.activateApp()
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
        Self.activateApp()
    }

    @objc func showVideoSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "Video")
        Self.activateApp()
    }

    @objc func showSubtitleSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(pane: "Subtitles")
        Self.activateApp()
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
        Self.activateApp()
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
        Self.activateApp()
    }

    @objc func searchSubtitles(_ sender: Any?) {
        SubtitleSearchWindowController.shared.showWindow(sender)
        Self.activateApp()
    }

    @objc func convertMedia(_ sender: Any?) {
        ConverterWindowController.shared.showWindow(sender)
        Self.activateApp()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    /// The standard About panel with a short description and links.
    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ]
        credits.append(NSAttributedString(string: "A fast, lightweight video player for the Mac.\nPlays almost any file or stream.\n", attributes: body))
        let links: [(String, String)] = [
            ("Website and source", "https://github.com/amegh-ts/lumora"),
            ("Report a problem", "https://github.com/amegh-ts/lumora/issues"),
            ("Third-party licenses", "https://github.com/amegh-ts/lumora/blob/main/THIRD_PARTY_NOTICES.md")
        ]
        for (index, link) in links.enumerated() {
            var attributes = body
            attributes[.link] = URL(string: link.1)
            credits.append(NSAttributedString(string: link.0, attributes: attributes))
            if index < links.count - 1 {
                credits.append(NSAttributedString(string: "  ·  ", attributes: body))
            }
        }
        credits.append(NSAttributedString(string: "\n\nBuilt on mpv, FFmpeg and libplacebo (LGPL).", attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        Self.activateApp()
    }

    @objc func showShortcuts(_ sender: Any?) {
        KeyboardShortcutsWindowController.shared.showWindow(sender)
        Self.activateApp()
    }
}
