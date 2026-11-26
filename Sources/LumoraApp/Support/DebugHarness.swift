import Foundation

/// Timestamped event log for stream timing tests (DEBUG only, LUMORA_TIMELINE=1).
enum DebugTimeline {
    nonisolated(unsafe) static let start = Date()
    static func log(_ event: String) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["LUMORA_TIMELINE"] != nil else { return }
            print(String(format: "[time %6.2fs] ", Date().timeIntervalSince(start)) + event)
            fflush(stdout)
        #endif
    }
}

/// Test-only switches. Always false in release builds.
enum DebugMode {
    /// LUMORA_KEEP_CONTROLS=1: never auto-hide the control bar (for screenshots).
    static var keepControls: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["LUMORA_KEEP_CONTROLS"] != nil
        #else
            return false
        #endif
    }
    /// LUMORA_BACKGROUND=1: never activate or bring windows forward, keep rendering while covered.
    static var background: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["LUMORA_BACKGROUND"] != nil
        #else
            return false
        #endif
    }
}

#if DEBUG
    import AppKit
    import MediaPlayer

    @MainActor
    enum DebugHarness {
        static func run(open: (([URL]) -> Void)) {
            let environment = ProcessInfo.processInfo.environment
            // LUMORA_CRASH_REPORT=/path/to/report.ips → print the scrubbed report and issue link length.
            if let path = environment["LUMORA_CRASH_REPORT"] {
                if let report = CrashReporter.report(from: URL(fileURLWithPath: path)) {
                    print("[debug] crash title=\(report.title)\n\(report.body)")
                    print("[debug] crash issue url length=\(CrashReporter.issueURL(for: report)?.absoluteString.count ?? -1)")
                } else {
                    print("[debug] crash report unreadable")
                }
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.5)
                return
            }
            // LUMORA_CHANNELS_TEST="url|/path/shot.png" → add a channel list (not saved), open the Live TV
            // panel, print counts and save a picture of the player window.
            // LUMORA_CHANNELS_PLAY="name" tunes to that channel; LUMORA_CHANNELS_STEPS=3 then presses
            // channel up three times, 6 s apart.
            if let entry = environment["LUMORA_CHANNELS_TEST"] {
                let parts = entry.split(separator: "|").map(String.init)
                if let url = URL(string: parts[0]) {
                    ChannelStore.shared.loadIfNeeded()
                    ChannelStore.shared.addSource(url: url, name: "iptv-org")
                    let player = { NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.first }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { player()?.setChannelPanel(visible: true) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        let store = ChannelStore.shared
                        print("[debug] channels=\(store.all.count) numbered=\(store.all.compactMap { store.number(of: $0) }.count)")
                        if let name = environment["LUMORA_CHANNELS_PLAY"], let channel = store.all.first(where: { $0.name.hasPrefix(name) }),
                            let player = player()
                        {
                            player.liveTV.ring = store.all
                            player.tune(to: channel)
                            print("[debug] tuned \(channel.name) number=\(store.number(of: channel) ?? -1)")
                        }
                        let steps = Int(environment["LUMORA_CHANNELS_STEPS"] ?? "0") ?? 0
                        for step in 0..<steps {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6 * Double(step + 1)) {
                                guard let player = player() else { return }
                                player.stepChannel(1)
                                print("[debug] step \(step + 1) → \(player.liveTV.current?.name ?? "-") skipped=\(player.liveTV.skipped)")
                            }
                        }
                        let finish = 7 + 6 * Double(steps)
                        DispatchQueue.main.asyncAfter(deadline: .now() + finish) {
                            if let player = player() {
                                let engine = player.engine
                                print(
                                    "[debug] now \(player.liveTV.current?.name ?? "-") playing=\(engine.isPlaying) live=\(engine.isLive) unavailable=\(store.unavailable.count) recent=\(store.recent.count)"
                                )
                                if parts.count > 1, let window = player.view.window, let frameView = window.contentView?.superview,
                                    let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                                {
                                    player.showChannelInfo()
                                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                                }
                            }
                            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.5)
                        }
                    }
                }
                return
            }
            // LUMORA_WINDOW_SHOTS=dir LUMORA_WINDOWS="showLibrary:,convertMedia:" → open each window
            // through its app action and save a picture of it.
            if let directory = environment["LUMORA_WINDOW_SHOTS"] {
                captureWindows(
                    to: URL(fileURLWithPath: directory),
                    actions: (environment["LUMORA_WINDOWS"] ?? "showLibrary:,searchSubtitles:,convertMedia:,showShortcuts:").split(separator: ",").map(
                        String.init),
                    appearance: environment["LUMORA_APPEARANCE"])
                return
            }
            if let directory = environment["LUMORA_SETTINGS_SHOTS"] {
                captureSettings(to: URL(fileURLWithPath: directory), appearance: environment["LUMORA_APPEARANCE"])
                return
            }
            if let path = environment["LUMORA_OPEN"] {
                open([path.hasPrefix("http") ? URL(string: path)! : URL(fileURLWithPath: path)])
                if environment["LUMORA_MUTE"] != nil,
                    let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first
                {
                    player.engine.toggleMute()
                }
            }
            // LUMORA_SKIPS="8:10,12:-10" → at 8 s skip +10 s, at 12 s skip -10 s.
            for entry in (environment["LUMORA_SKIPS"] ?? "").split(separator: ",") {
                let parts = entry.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) {
                    guard let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                    DebugTimeline.log("skip \(parts[1]) at t=\(String(format: "%.1f", player.engine.currentTime))")
                    player.engine.skip(parts[1])
                }
            }
            // LUMORA_QUALITY="15:720" → at 15 s list the stream variants and switch to 720p.
            if let entry = environment["LUMORA_QUALITY"] {
                let parts = entry.split(separator: ":").compactMap { Double($0) }
                if parts.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) {
                        guard let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                        let choices = StreamVariant.menuChoices(from: player.engine.streamVariants)
                        DebugTimeline.log("variants " + choices.map { "\($0.label)[\($0.detail)]\($0.isSelected ? "*" : "")" }.joined(separator: " "))
                        if let target = choices.first(where: { $0.height == Int(parts[1]) }) {
                            DebugTimeline.log("select \(target.label) at t=\(String(format: "%.1f", player.engine.currentTime))")
                            player.engine.selectStreamVariant(target.id)
                        }
                    }
                }
            }
            // LUMORA_SUBSTYLE="box:#FFD60A:80" → subtitle background, colour and position (settings untouched).
            if let entry = environment["LUMORA_SUBSTYLE"] {
                let parts = entry.split(separator: ":").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard parts.count == 3, let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                    player.engine.setSubtitleStyle(
                        font: "Avenir Next", color: parts[1], background: SubtitleBackground(rawValue: parts[0]) ?? .outline,
                        position: Double(parts[2]) ?? 100)
                }
            }
            // LUMORA_PIP="2:6:/path/frame.png" → PiP frame pipeline from 2 s to 6 s, last frame saved.
            if let entry = environment["LUMORA_PIP"] {
                let parts = entry.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count >= 2, let begin = Double(parts[0]), let end = Double(parts[1]) {
                    let player = { NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.first }
                    DispatchQueue.main.asyncAfter(deadline: .now() + begin) {
                        print("[debug] " + (player()?.debugPictureInPicture(start: true, frameFile: nil) ?? "no player"))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + end) {
                        let file = parts.count == 3 ? URL(fileURLWithPath: parts[2]) : nil
                        print("[debug] " + (player()?.debugPictureInPicture(start: false, frameFile: file) ?? "no player"))
                    }
                }
            }
            // LUMORA_PANEL_ALL=3 → at 3 s switch the Live TV panel to its All tab.
            if let delay = environment["LUMORA_PANEL_ALL"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.first?.channelPanel.debugSelectAllTab()
                }
            }
            // LUMORA_PANEL_STEPS="4:category:News,6:back,8:country:in" → drive the Live TV panel; a
            // snapshot of the player window is saved per step to LUMORA_PANEL_SHOTS.
            for entry in (environment["LUMORA_PANEL_STEPS"] ?? "").split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                    let result = player.channelPanel.debugStep(parts[1])
                    print("[debug] panel \(parts[1]) → \(result) watching=\(player.liveTV.current?.name ?? "-")")
                    if let folder = environment["LUMORA_PANEL_SHOTS"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            guard let frameView = player.view.window?.contentView?.superview,
                                let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                            else { return }
                            frameView.cacheDisplay(in: frameView.bounds, to: rep)
                            let name = parts[1].replacingOccurrences(of: ":", with: "-")
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(parts[0])-\(name).png"))
                        }
                    }
                }
            }
            // LUMORA_ARTWORK_TEST=4 → at 4 s ask for the Now Playing artwork from a background queue,
            // the way MediaPlayer does (this used to trap).
            if let delay = environment["LUMORA_ARTWORK_TEST"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
                        print("[debug] artwork none")
                        return
                    }
                    nonisolated(unsafe) let item = artwork
                    DispatchQueue.global().async {
                        let image = item.image(at: CGSize(width: 300, height: 300))
                        print("[debug] artwork from background queue ok=\(image != nil)")
                    }
                }
            }
            // LUMORA_PIP_THREADS=4 → call the PiP delegate from a background queue (#50).
            if let delay = environment["LUMORA_PIP_THREADS"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.first?.debugPictureInPictureThreads()
                }
            }
            // LUMORA_CROP="2:2.35" → at 2 s crop to 2.35:1 and reshape the window.
            if let entry = environment["LUMORA_CROP"] {
                let parts = entry.split(separator: ":").compactMap { Double($0) }
                if parts.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) {
                        guard let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                        player.engine.setCrop(aspect: parts[1])
                        player.reshapeWindowForPicture()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            print("[debug] crop size=\(player.engine.videoSize) content=\(player.view.window?.contentView?.frame.size ?? .zero)")
                        }
                    }
                }
            }
            // LUMORA_ACTIONS="2:actualSize:,3:showMediaInfo:" → send menu actions to the player.
            for entry in (environment["LUMORA_ACTIONS"] ?? "").split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first else { return }
                    let sent = NSApp.sendAction(Selector(String(parts[1])), to: player, from: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let size = player.view.window?.contentView?.frame.size ?? .zero
                        print("[debug] action \(parts[1]) sent=\(sent) content=\(Int(size.width))x\(Int(size.height))")
                    }
                }
            }
            if let minimizeAt = environment["LUMORA_MINIMIZE_AT"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + minimizeAt) {
                    NSApp.windows.first { $0.windowController is MainWindowController }?.miniaturize(nil)
                    print("[debug] minimized")
                }
            }
            if let restoreAt = environment["LUMORA_RESTORE_AT"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreAt) {
                    NSApp.windows.first { $0.windowController is MainWindowController }?.deminiaturize(nil)
                    print("[debug] restored")
                }
            }
            guard let directory = environment["LUMORA_SNAPSHOT_DIR"] else { return }
            let steps = (environment["LUMORA_SNAPSHOT_STEPS"] ?? "2").split(separator: ",").compactMap { Double($0) }
            for (index, delay) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent("step-\(index).png"))
                }
            }
            if let quit = steps.max() {
                DispatchQueue.main.asyncAfter(deadline: .now() + quit + 1) {
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                }
            }
        }

        private static func captureWindows(to directory: URL, actions: [String], appearance: String?) {
            if let appearance {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, action) in actions.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 1.5) {
                    let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                    NSApp.sendAction(Selector(action), to: nil, from: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let opened = NSApp.windows.filter {
                            $0.isVisible && !before.contains(ObjectIdentifier($0)) && !($0.windowController is MainWindowController)
                        }
                        let target =
                            opened.first ?? NSApp.windows.first { $0.isVisible && $0.title.isEmpty == false && !($0.windowController is MainWindowController) }
                        guard let window = target, let frameView = window.contentView?.superview,
                            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                        else {
                            print("[debug] window \(action) not found")
                            return
                        }
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        let name = action.replacingOccurrences(of: ":", with: "")
                        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(index)-\(name).png"))
                        print("[debug] window \(action) title=\(window.title) size=\(window.frame.size)")
                        window.orderOut(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(actions.count) * 1.5) {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }

        private static func captureSettings(to directory: URL, appearance: String?) {
            if let appearance {
                NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let titles = ["General", "Video", "Audio", "Subtitles", "Network", "Advanced"]
            for (index, title) in titles.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 0.9) {
                    SettingsWindowController.shared.show(pane: title)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 + Double(index) * 0.9) {
                    guard let window = SettingsWindowController.shared.window,
                        let frameView = window.contentView?.superview,
                        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
                    else { return }
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    let file = directory.appendingPathComponent("\(index)-\(title).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                    print("[debug] settings \(title) size=\(window.frame.size)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(titles.count) * 0.9) {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
        }

        private static func snapshot(to url: URL) {
            if let info = MediaInfoWindowController.shared.window, info.isVisible, let frameView = info.contentView?.superview,
                let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("info.png"))
            }
            let players = NSApp.windows.filter { $0.windowController is MainWindowController }
            FileHandle.standardError.write("[debug] player windows=\(players.count) visible=\(players.filter(\.isVisible).count)\n".data(using: .utf8)!)
            guard let window = players.first(where: \.isVisible),
                let view = window.contentView?.superview
            else { return }
            if let player = window.contentViewController as? PlayerViewController {
                let engine = player.engine
                print("[debug] controlsShowing=\(player.areControlsShowing)")
                print(
                    "[debug] audioDevices=\(player.engine.audioDevices.map(\.description)) current=\(player.engine.audioDevice) deinterlace=\(player.engine.deinterlace)"
                )
                print(
                    "[debug] playlist index=\(player.debugPlaylistIndex.map(String.init) ?? "-") items=\(player.debugPlaylistTitles.prefix(6)) count=\(player.debugPlaylistTitles.count)"
                )
                print(
                    "[debug] title=\(engine.currentItem?.title ?? "-") t=\(engine.currentTime) d=\(engine.duration) playing=\(engine.isPlaying) media=\(engine.hasMedia) size=\(engine.videoSize) audio=\(engine.audioTracks.map(\.displayName)) subs=\(engine.subtitleTracks.map(\.displayName)) chapters=\(engine.chapters.count) status=\(engine.statusMessage) live=\(engine.isLive) picture=\(engine.hasPicture) buffered=\(engine.bufferedRanges.map { String(format: "%.0f-%.0f", $0.lowerBound, $0.upperBound) }) tags=\(engine.mediaTags) content=\(window.contentLayoutRect.size) aspect=\(window.contentAspectRatio)"
                )
            }
            if let player = window.contentViewController as? PlayerViewController, player.engine.isActive {
                let shot = url.deletingPathExtension().path + "-vo.png"
                MPV.command(player.engine.handle, ["screenshot-to-file", shot, "window"])
                print("[debug] renderer=\(player.engine.renderer.rawValue) vo-shot=\(shot)")
                let names = [
                    "hwdec-current", "current-vo", "video-format", "demuxer-cache-state/total-bytes", "vd-lavc-threads", "swapchain-depth", "hwdec-extra-frames"
                ]
                let values = names.map { "\($0)=\(MPV.string(player.engine.handle, $0) ?? "-")" }
                print("[debug] mpv \(values.joined(separator: " "))")
            }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            print(
                "[debug] nowplaying state=\(MPNowPlayingInfoCenter.default().playbackState.rawValue) title=\(info[MPMediaItemPropertyTitle] ?? "-") elapsed=\(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?? "-") duration=\(info[MPMediaItemPropertyPlaybackDuration] ?? "-") rate=\(info[MPNowPlayingInfoPropertyPlaybackRate] ?? "-") artwork=\(info[MPMediaItemPropertyArtwork] != nil)"
            )
            if let action = ProcessInfo.processInfo.environment[
                "LUMORA_NP_ACTION_" + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: "_")]
            {
                let status = NowPlayingService.shared.perform { player in
                    switch action {
                    case "toggle": player.engine.togglePlayback()
                    case "skip": player.engine.skip(NowPlayingService.skipInterval)
                    case "seek20": player.engine.seek(to: 20)
                    case "rate2": player.engine.setRate(2)
                    default: break
                    }
                }
                print("[debug] np-action \(action) status=\(status.rawValue)")
            }
            if ProcessInfo.processInfo.environment["LUMORA_MENU_TEST"] != nil, let main = NSApp.mainMenu {
                for item in main.items {
                    if let submenu = item.submenu { submenu.delegate?.menuNeedsUpdate?(submenu) }
                    let titles = item.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
                    print("[menu] \(item.title): \(titles.joined(separator: " | "))")
                }
                func dynamicTitles(_ top: String, _ title: String) -> String {
                    guard let menu = main.item(withTitle: top)?.submenu?.item(withTitle: title)?.submenu else { return "missing" }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    return menu.items.map { ($0.state == .on ? "✓" : "") + $0.title }.joined(separator: ", ")
                }
                print("[menu] dynamic audio: \(dynamicTitles("Audio", "Audio Track"))")
                print("[menu] dynamic subs: \(dynamicTitles("Subtitles", "Subtitle Track"))")
                print("[menu] dynamic chapters: \(dynamicTitles("Playback", "Chapters"))")
                print("[menu] dynamic speed: \(dynamicTitles("Playback", "Speed"))")
                if let player = window.contentViewController as? PlayerViewController {
                    let before = player.engine.isPlaying
                    let space = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: " ",
                        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    window.makeKeyAndOrderFront(nil)
                    let handled = main.performKeyEquivalent(with: space)
                    print("[menu] space handled=\(handled) playingBefore=\(before)")
                    SettingsWindowController.shared.show(pane: "Subtitles")
                    let blocked = main.performKeyEquivalent(with: space)
                    print("[menu] space while Settings key handled=\(blocked)")
                    SettingsWindowController.shared.close()
                }
            }
            print("[debug] window=\(window.frame.size) content=\(window.contentLayoutRect.size)")
            print("[debug] menu=\(NSApp.mainMenu?.items.map(\.title) ?? []) appMenu=\(NSApp.mainMenu?.items.first?.submenu?.items.first?.title ?? "")")
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
