import AppKit

/// Dynamic submenus of the menu bar, filled from the active player when they open.
enum DynamicMenu {
    case speed
    case audioTracks
    case subtitleTracks
    case chapters
    case bookmarks
    case videoSize
    case repeatMode
    case streamQuality
}

extension PlayerViewController {
    func fill(_ kind: DynamicMenu, into menu: NSMenu) {
        switch kind {
        case .speed:
            for speed: Float in [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4] {
                let title = speed == 1 ? "Normal" : String(format: "%g×", speed)
                menu.addItem(
                    ClosureMenuItem(title, checked: abs(engine.rate - speed) < 0.01) { [weak self] in
                        self?.setSpeed(speed)
                    })
            }
        case .audioTracks:
            if engine.audioTracks.isEmpty {
                menu.addItem(ClosureMenuItem("No Audio Tracks", enabled: false) {})
            }
            for track in engine.audioTracks {
                menu.addItem(
                    ClosureMenuItem(track.displayName, checked: track.isSelected) { [weak self] in
                        self?.engine.selectAudioTrack(track.id)
                        self?.osd.show("Audio: \(track.displayName)", symbol: "speaker.wave.2.fill")
                    })
            }
        case .subtitleTracks:
            menu.addItem(
                ClosureMenuItem("Off", checked: engine.selectedSubtitleTrackID == nil) { [weak self] in
                    self?.engine.selectSubtitleTrack(nil)
                    self?.osd.show("Subtitles off", symbol: "captions.bubble")
                })
            for track in engine.subtitleTracks {
                menu.addItem(
                    ClosureMenuItem(track.displayName, checked: track.isSelected) { [weak self] in
                        self?.engine.selectSubtitleTrack(track.id)
                        self?.osd.show("Subtitles: \(track.displayName)", symbol: "captions.bubble.fill")
                    })
            }
        case .chapters:
            if engine.chapters.isEmpty {
                menu.addItem(ClosureMenuItem("No Chapters", enabled: false) {})
            }
            let current = engine.chapters.lastIndex { $0.time <= engine.currentTime + 0.5 }
            for (index, chapter) in engine.chapters.enumerated() {
                let title = chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
                menu.addItem(
                    ClosureMenuItem("\(title)\t\(TimeFormatter.string(chapter.time))", checked: index == current) { [weak self] in
                        self?.engine.seek(to: chapter.time)
                    })
            }
        case .bookmarks:
            let bookmarks = engine.currentItem.flatMap { library.record(for: $0.url)?.bookmarks } ?? []
            if bookmarks.isEmpty {
                menu.addItem(ClosureMenuItem("No Bookmarks", enabled: false) {})
            }
            for bookmark in bookmarks {
                menu.addItem(ClosureMenuItem(bookmark.label) { [weak self] in self?.engine.seek(to: bookmark.time) })
            }
        case .streamQuality:
            let choices = StreamVariant.menuChoices(from: engine.streamVariants)
            if choices.isEmpty {
                let note = engine.currentItem?.url.isFileURL == false ? "Single Quality Stream" : "Online Videos Only"
                menu.addItem(ClosureMenuItem(note, enabled: false) {})
            }
            for variant in choices {
                let title = variant.detail.isEmpty ? variant.label : "\(variant.label)\t\(variant.detail)"
                menu.addItem(
                    ClosureMenuItem(title, checked: variant.isSelected) { [weak self] in
                        self?.engine.selectStreamVariant(variant.id)
                        self?.osd.show("Quality: \(variant.label)", symbol: "sparkles.tv")
                    })
            }
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem("Default for New Videos…") {
                    (NSApp.delegate as? AppDelegate)?.showVideoSettings(nil)
                })
        case .videoSize:
            let options: [(VideoGravityPreference, String)] = [(.aspect, "Fit"), (.fill, "Fill (Crop Edges)"), (.stretch, "Stretch")]
            for (preference, title) in options {
                menu.addItem(
                    ClosureMenuItem(title, checked: settings.videoGravity == preference) { [weak self] in
                        self?.settings.videoGravity = preference
                    })
            }
        case .repeatMode:
            let options: [(RepeatMode, String)] = [(.off, "Off"), (.all, "All Items"), (.one, "Current Item")]
            for (mode, title) in options {
                menu.addItem(
                    ClosureMenuItem(title, checked: settings.repeatMode == mode) { [weak self] in
                        self?.settings.repeatMode = mode
                    })
            }
        }
    }

    // MARK: - Menu bar actions (responder chain)

    @objc func jumpForward(_ sender: Any?) { engine.skip(10) }
    @objc func jumpBackward(_ sender: Any?) { engine.skip(-10) }
    @objc func jumpForwardLong(_ sender: Any?) { engine.skip(60) }
    @objc func jumpBackwardLong(_ sender: Any?) { engine.skip(-60) }
    @objc func nextFrame(_ sender: Any?) { engine.stepFrame(forward: true) }
    @objc func previousFrame(_ sender: Any?) { engine.stepFrame(forward: false) }
    @objc func speedUp(_ sender: Any?) { setSpeed(min(4, engine.rate + 0.25)) }
    @objc func slowDown(_ sender: Any?) { setSpeed(max(0.25, engine.rate - 0.25)) }
    @objc func normalSpeed(_ sender: Any?) { setSpeed(1) }
    @objc func addBookmarkAction(_ sender: Any?) { addBookmark() }
    @objc func toggleShuffle(_ sender: Any?) {
        settings.shuffle.toggle()
        osd.show(settings.shuffle ? "Shuffle on" : "Shuffle off", symbol: "shuffle")
    }

    @objc func volumeUp(_ sender: Any?) { changeVolume(by: 0.05) }
    @objc func volumeDown(_ sender: Any?) { changeVolume(by: -0.05) }
    @objc func toggleMute(_ sender: Any?) {
        engine.toggleMute()
        osd.show(engine.isMuted ? "Sound on" : "Muted", symbol: engine.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    }

    @objc func addSubtitleFile(_ sender: Any?) { chooseSubtitleFile() }
    @objc func audioEarlier(_ sender: Any?) { adjustAudioDelay(-0.1) }
    @objc func audioLater(_ sender: Any?) { adjustAudioDelay(0.1) }
    @objc func resetAudioDelay(_ sender: Any?) { adjustAudioDelay(nil) }

    /// Audio/video sync for the current file.
    func adjustAudioDelay(_ delta: TimeInterval?) {
        engine.adjustAudioDelay(by: delta)
        osd.show(String(format: "Audio delay %+.1f s", engine.audioDelay), symbol: "waveform")
    }
    @objc func subtitleEarlier(_ sender: Any?) { adjustSubtitleDelay(-0.1) }
    @objc func subtitleLater(_ sender: Any?) { adjustSubtitleDelay(0.1) }
    @objc func resetSubtitleDelay(_ sender: Any?) { adjustSubtitleDelay(nil) }
    @objc func subtitleBigger(_ sender: Any?) { changeSubtitleSize(by: 2) }
    @objc func subtitleSmaller(_ sender: Any?) { changeSubtitleSize(by: -2) }
    @objc func resetSubtitleSize(_ sender: Any?) {
        settings.subtitleSize = 24
        osd.show("Subtitle size reset", symbol: "textformat.size")
    }

    @objc func rotateVideo(_ sender: Any?) {
        engine.rotate()
        osd.show("Rotated", symbol: "rotate.right")
    }

    /// Full screen from mini player: drop the floating mini window state first.
    func leaveMiniPlayerIfNeeded() {
        guard miniPlayerRestoreFrame != nil else { return }
        toggleMiniPlayer(nil)
    }

    private func changeSubtitleSize(by delta: Double) {
        settings.subtitleSize = min(48, max(14, settings.subtitleSize + delta))
        osd.show("Subtitle size \(Int(settings.subtitleSize)) pt", symbol: "textformat.size")
    }
}
