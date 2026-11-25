import AppKit

/// Main menu that lets plain-key shortcuts (Space, arrows, letters) fire only while a player window
/// is key and no text field is being edited, so typing in Settings or the URL sheet is never hijacked.
final class GuardedMainMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            guard let window = NSApp.keyWindow,
                window.windowController is MainWindowController,
                !(window.firstResponder is NSText)
            else { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Fills a dynamic submenu from the active player each time it opens.
final class DynamicMenuFiller: NSObject, NSMenuDelegate {
    private let kind: DynamicMenu

    init(_ kind: DynamicMenu) {
        self.kind = kind
    }

    /// No shortcuts in here; tells AppKit not to rebuild this menu on every key press.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let window = NSApp.keyWindow?.windowController is MainWindowController ? NSApp.keyWindow : NSApp.mainWindow
            guard let player = window?.contentViewController as? PlayerViewController, player.engine.hasMedia else {
                menu.addItem(ClosureMenuItem("Nothing Playing", enabled: false) {})
                return
            }
            player.fill(kind, into: menu)
        }
    }
}

/// Open Recent, filled from the library each time it opens.
final class RecentMenuFiller: NSObject, NSMenuDelegate {
    private let open: (URL) -> Void

    init(open: @escaping (URL) -> Void) {
        self.open = open
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            let records = LibraryStore.shared.recent(limit: 12)
            if records.isEmpty {
                menu.addItem(ClosureMenuItem("No Recent Items", enabled: false) {})
                return
            }
            for record in records {
                let item = ClosureMenuItem(record.title) { [open] in open(record.url) }
                if record.url.isFileURL {
                    let icon = NSWorkspace.shared.icon(forFile: record.url.path)
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                } else {
                    item.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
        }
    }
}

/// macOS appends system items (Emoji & Symbols, Enter Full Screen) to Edit and View, sometimes
/// more than once; keep only the first item of each title.
final class DuplicateItemRemover: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        var seen = Set<String>()
        for item in menu.items where !item.isSeparatorItem {
            if seen.contains(item.title) {
                menu.removeItem(item)
            } else {
                seen.insert(item.title)
            }
        }
    }
}

@MainActor
enum MainMenuBuilder {
    private static var fillers: [NSObject] = []
    private static let duplicateRemover = DuplicateItemRemover()

    static func build(openRecent: @escaping (URL) -> Void) -> NSMenu {
        fillers.removeAll()
        // Keep the Edit menu to the standard commands; macOS otherwise appends Dictation and
        // Emoji items (and repeats them after mpv's own menu setup).
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        let main = GuardedMainMenu()
        let space = " "
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

        let app = submenu(main, "Lumora")
        add(app, "About Lumora", #selector(AppDelegate.showAbout(_:)))
        add(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", symbol: "gearshape")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        add(app, "Hide Lumora", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit Lumora", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu(main, "File")
        add(file, "New Player Window", #selector(AppDelegate.newPlayerWindow(_:)), "n", symbol: "macwindow.badge.plus")
        add(file, "Open…", #selector(AppDelegate.openDocument(_:)), "o", symbol: "folder")
        add(file, "Open URL…", #selector(AppDelegate.openNetworkStream(_:)), "u", symbol: "link")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        let recentFiller = RecentMenuFiller(open: openRecent)
        fillers.append(recentFiller)
        recentMenu.delegate = recentFiller
        recent.submenu = recentMenu
        recent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        file.addItem(recent)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu(main, "Edit")
        edit.delegate = duplicateRemover
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let playback = submenu(main, "Playback")
        add(playback, "Play / Pause", #selector(PlayerViewController.togglePlayback(_:)), space, [], symbol: "playpause")
        add(playback, "Stop", #selector(PlayerViewController.stopPlayback(_:)), ".", symbol: "stop")
        playback.addItem(.separator())
        add(playback, "Jump Forward 10 s", #selector(PlayerViewController.jumpForward(_:)), right, [], symbol: "goforward.10")
        add(playback, "Jump Back 10 s", #selector(PlayerViewController.jumpBackward(_:)), left, [], symbol: "gobackward.10")
        add(playback, "Jump Forward 1 min", #selector(PlayerViewController.jumpForwardLong(_:)), right, [.option])
        add(playback, "Jump Back 1 min", #selector(PlayerViewController.jumpBackwardLong(_:)), left, [.option])
        add(playback, "Next Frame", #selector(PlayerViewController.nextFrame(_:)), ".", [])
        add(playback, "Previous Frame", #selector(PlayerViewController.previousFrame(_:)), ",", [])
        playback.addItem(.separator())
        dynamic(playback, "Speed", .speed, symbol: "gauge.with.dots.needle.67percent")
        add(playback, "Faster", #selector(PlayerViewController.speedUp(_:)), "]", [])
        add(playback, "Slower", #selector(PlayerViewController.slowDown(_:)), "[", [])
        add(playback, "Normal Speed", #selector(PlayerViewController.normalSpeed(_:)), "=", [])
        playback.addItem(.separator())
        add(playback, "A-B Loop", #selector(PlayerViewController.cycleABLoop(_:)), "l", [], symbol: "repeat")
        dynamic(playback, "Chapters", .chapters, symbol: "list.number")
        add(playback, "Go to Time…", #selector(PlayerViewController.goToTime(_:)), "j", symbol: "clock.arrow.circlepath")
        add(playback, "Add Bookmark", #selector(PlayerViewController.addBookmarkAction(_:)), "b", [], symbol: "bookmark")
        dynamic(playback, "Bookmarks", .bookmarks)
        playback.addItem(.separator())
        add(playback, "Next Item", #selector(PlayerViewController.nextItem(_:)), right, [.command], symbol: "forward.end")
        add(playback, "Previous Item", #selector(PlayerViewController.previousItem(_:)), left, [.command], symbol: "backward.end")
        dynamic(playback, "Repeat", .repeatMode)
        add(playback, "Shuffle", #selector(PlayerViewController.toggleShuffle(_:)), symbol: "shuffle")

        let audio = submenu(main, "Audio")
        add(audio, "Volume Up", #selector(PlayerViewController.volumeUp(_:)), up, [], symbol: "speaker.plus")
        add(audio, "Volume Down", #selector(PlayerViewController.volumeDown(_:)), down, [], symbol: "speaker.minus")
        add(audio, "Mute", #selector(PlayerViewController.toggleMute(_:)), "m", [], symbol: "speaker.slash")
        audio.addItem(.separator())
        dynamic(audio, "Audio Track", .audioTracks, symbol: "waveform")
        add(audio, "Next Audio Track", #selector(PlayerViewController.cycleAudio(_:)), "a", [])
        dynamic(audio, "Output Device", .audioDevice, symbol: "hifispeaker")
        add(audio, "Volume Boost", #selector(PlayerViewController.toggleVolumeBoost(_:)), symbol: "speaker.wave.3")
        audio.addItem(.separator())
        add(audio, "Audio Earlier (−0.1 s)", #selector(PlayerViewController.audioEarlier(_:)), "-", [])
        add(audio, "Audio Later (+0.1 s)", #selector(PlayerViewController.audioLater(_:)), "=", [.shift])
        add(audio, "Reset Audio Delay", #selector(PlayerViewController.resetAudioDelay(_:)))
        audio.addItem(.separator())
        add(audio, "Equalizer…", #selector(AppDelegate.showAudioSettings(_:)), symbol: "slider.vertical.3")

        let subtitles = submenu(main, "Subtitles")
        dynamic(subtitles, "Subtitle Track", .subtitleTracks, symbol: "captions.bubble")
        add(subtitles, "Next Subtitle", #selector(PlayerViewController.cycleSubtitles(_:)), "t", [])
        subtitles.addItem(.separator())
        add(subtitles, "Add Subtitle File…", #selector(PlayerViewController.addSubtitleFile(_:)), symbol: "doc.badge.plus")
        add(subtitles, "Search Online…", #selector(AppDelegate.searchSubtitles(_:)), symbol: "magnifyingglass")
        subtitles.addItem(.separator())
        add(subtitles, "Show Earlier (−0.1 s)", #selector(PlayerViewController.subtitleEarlier(_:)), "z", [])
        add(subtitles, "Show Later (+0.1 s)", #selector(PlayerViewController.subtitleLater(_:)), "x", [])
        add(subtitles, "Reset Delay", #selector(PlayerViewController.resetSubtitleDelay(_:)))
        subtitles.addItem(.separator())
        add(subtitles, "Bigger", #selector(PlayerViewController.subtitleBigger(_:)), "+", [.command, .option])
        add(subtitles, "Smaller", #selector(PlayerViewController.subtitleSmaller(_:)), "-", [.command, .option])
        add(subtitles, "Reset Size", #selector(PlayerViewController.resetSubtitleSize(_:)))
        subtitles.addItem(.separator())
        add(subtitles, "Subtitle Settings…", #selector(AppDelegate.showSubtitleSettings(_:)))

        let video = submenu(main, "Video")
        add(video, "Take Screenshot", #selector(PlayerViewController.takeScreenshot(_:)), "s", [.command, .shift], symbol: "camera")
        video.addItem(.separator())
        dynamic(video, "Video Size", .videoSize, symbol: "aspectratio")
        dynamic(video, "Quality", .streamQuality, symbol: "sparkles.tv")
        dynamic(video, "Aspect Ratio", .aspectRatio, symbol: "rectangle.ratio.16.to.9")
        dynamic(video, "Crop", .crop, symbol: "crop")
        dynamic(video, "Deinterlace", .deinterlace, symbol: "rectangle.split.3x1")
        add(video, "Rotate 90°", #selector(PlayerViewController.rotateVideo(_:)), "r", [.command, .option], symbol: "rotate.right")
        video.addItem(.separator())
        add(video, "Video Settings…", #selector(AppDelegate.showVideoSettings(_:)), symbol: "slider.horizontal.3")

        let view = submenu(main, "View")
        view.delegate = duplicateRemover
        // AppKit's own action; DuplicateItemRemover drops the copy macOS may add.
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        add(view, "Mini Player", #selector(PlayerViewController.toggleMiniPlayer(_:)), "m", [.command, .option], symbol: "pip")
        add(view, "Picture in Picture", #selector(PlayerViewController.togglePictureInPicture(_:)), "p", [.command, .option], symbol: "pip.enter")
        view.addItem(.separator())
        add(view, "Half Size", #selector(PlayerViewController.halfSize(_:)), "0")
        add(view, "Actual Size", #selector(PlayerViewController.actualSize(_:)), "1")
        add(view, "Double Size", #selector(PlayerViewController.doubleSize(_:)), "2")
        add(view, "Fit to Screen", #selector(PlayerViewController.fitToScreen(_:)), "3")
        view.addItem(.separator())
        add(view, "Keep on Top", #selector(PlayerViewController.toggleKeepOnTop(_:)), "t", [.command, .option], symbol: "pin")
        view.addItem(.separator())
        add(view, "Show Playlist", #selector(PlayerViewController.togglePlaylist(_:)), "p", [], symbol: "sidebar.right")
        add(view, "Library", #selector(AppDelegate.showLibrary(_:)), "l", [.command, .shift], symbol: "books.vertical")

        let tools = submenu(main, "Tools")
        add(tools, "Convert Media…", #selector(AppDelegate.convertMedia(_:)), symbol: "arrow.triangle.2.circlepath")

        let window = submenu(main, "Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Media Info", #selector(PlayerViewController.showMediaInfo(_:)), "i", symbol: "info.circle")
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        let help = submenu(main, "Help")
        add(help, "Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/", symbol: "keyboard")
        add(help, "Lumora on GitHub", #selector(AppDelegate.openProjectPage(_:)))
        add(help, "Report an Issue…", #selector(AppDelegate.reportIssue(_:)))
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        parent.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command],
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
        return item
    }

    private static func dynamic(_ menu: NSMenu, _ title: String, _ kind: DynamicMenu, symbol: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        let filler = DynamicMenuFiller(kind)
        fillers.append(filler)
        submenu.delegate = filler
        item.submenu = submenu
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }
}
