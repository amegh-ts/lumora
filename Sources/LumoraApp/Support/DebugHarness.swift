#if DEBUG
    import AppKit
    import MediaPlayer

    @MainActor
    enum DebugHarness {
        static func run(open: (([URL]) -> Void)) {
            let environment = ProcessInfo.processInfo.environment
            if let directory = environment["LUMORA_SETTINGS_SHOTS"] {
                captureSettings(to: URL(fileURLWithPath: directory), appearance: environment["LUMORA_APPEARANCE"])
                return
            }
            if let path = environment["LUMORA_OPEN"] {
                open([URL(fileURLWithPath: path)])
                if environment["LUMORA_MUTE"] != nil,
                    let player = NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }).first
                {
                    player.engine.toggleMute()
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
            let players = NSApp.windows.filter { $0.windowController is MainWindowController }
            FileHandle.standardError.write("[debug] player windows=\(players.count) visible=\(players.filter(\.isVisible).count)\n".data(using: .utf8)!)
            guard let window = players.first(where: \.isVisible),
                let view = window.contentView?.superview
            else { return }
            if let player = window.contentViewController as? PlayerViewController {
                let engine = player.engine
                print(
                    "[debug] title=\(engine.currentItem?.title ?? "-") t=\(engine.currentTime) d=\(engine.duration) playing=\(engine.isPlaying) media=\(engine.hasMedia) size=\(engine.videoSize) audio=\(engine.audioTracks.map(\.displayName)) subs=\(engine.subtitleTracks.map(\.displayName)) chapters=\(engine.chapters.count) status=\(engine.statusMessage)"
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
