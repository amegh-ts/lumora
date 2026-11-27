import AppKit

/// What the player knows about live TV: the channel on screen, the list channel up/down moves
/// through, and the channel before it (for "previous channel").
struct LiveTVState {
    var ring: [Channel] = []
    var ringTitle = ""
    var current: Channel?
    var previous: Channel?
    /// +1 / -1 while switching with channel up/down, 0 after a direct pick.
    var direction = 0
    var skipped = 0
}

extension PlayerViewController: ChannelPanelDelegate {
    var isWatchingChannel: Bool { engine.currentItem?.kind == .channel }
    var isChannelPanelVisible: Bool { !channelPanel.isHidden }

    // MARK: Panel

    func installLiveTV() {
        // Nothing loads at launch: Live TV reads its lists only when opened or used.
        channelPanel.delegate = self
        channelPanel.isHidden = true
        channelBanner.onStar = { [weak self] in self?.toggleCurrentFavourite() }
        channelBanner.onCancelSkip = { [weak self] in self?.cancelSkip() }
    }

    @objc func toggleChannelPanel(_ sender: Any?) {
        setChannelPanel(visible: !isChannelPanelVisible)
    }

    func setChannelPanel(visible: Bool, focusSearch: Bool = false) {
        if visible {
            leaveMiniPlayerIfNeeded()
            channelPanel.playingKey = liveTV.current?.key
            channelPanel.prepareToShow()
        }
        channelPanel.isHidden = !visible
        scheduleLiveTVUnload()
        controlsLeadingForPanel.isActive = visible
        // The banner moves beside the panel instead of covering it.
        bannerLeadingForPanel.isActive = visible
        controls.setChannelsButtonActive(visible)
        if visible, focusSearch {
            channelPanel.focusSearch()
        } else if !visible {
            view.window?.makeFirstResponder(view)
        }
    }

    func channelPanelDidClose(_ panel: ChannelPanel) {
        setChannelPanel(visible: false)
    }

    func channelPanel(_ panel: ChannelPanel, play channel: Channel, ring: [Channel], ringTitle: String) {
        liveTV.ring = ring
        liveTV.ringTitle = ringTitle
        liveTV.direction = 0
        tune(to: channel)
    }

    // MARK: Tuning

    /// Plays a channel without touching the playlist of files.
    func tune(to channel: Channel) {
        cancelSkip(keepDirection: true)
        if let current = liveTV.current, current.key != channel.key {
            liveTV.previous = current
        }
        liveTV.current = channel
        saveProgress(force: true)
        engine.load(channel.playbackItem)
        channelPanel.playingKey = channel.key
        updateChannelControls()
        channelBanner.show(channel, number: ChannelStore.shared.number(of: channel), favourite: ChannelStore.shared.isFavourite(channel))
    }

    /// Channel up (+1) / down (-1) within the list the channel was picked from.
    func stepChannel(_ delta: Int) {
        let ring = liveTV.ring.isEmpty ? ChannelStore.shared.all : liveTV.ring
        guard !ring.isEmpty else { return }
        let start = liveTV.current.flatMap { current in ring.firstIndex { $0.key == current.key } } ?? (delta > 0 ? -1 : 0)
        // Skip channels already known to be down this session.
        var index = start
        for _ in 0..<ring.count {
            index = (index + delta + ring.count) % ring.count
            if !ChannelStore.shared.isUnavailable(ring[index]) { break }
        }
        liveTV.direction = delta
        tune(to: ring[index])
    }

    @objc func channelUp(_ sender: Any?) { stepChannel(1) }
    @objc func channelDown(_ sender: Any?) { stepChannel(-1) }

    /// Back to the channel watched before this one.
    @objc func previousChannel(_ sender: Any?) {
        guard let previous = liveTV.previous else { return }
        liveTV.direction = 0
        tune(to: previous)
    }

    @objc func toggleCurrentFavourite(_ sender: Any? = nil) {
        guard let channel = liveTV.current, isWatchingChannel else { return }
        ChannelStore.shared.toggleFavourite(channel)
        let favourite = ChannelStore.shared.isFavourite(channel)
        channelBanner.show(channel, number: ChannelStore.shared.number(of: channel), favourite: favourite, duration: 2)
        osd.show(favourite ? "Added to Favourites" : "Removed from Favourites", symbol: favourite ? "star.fill" : "star", duration: 1.2)
    }

    @objc func showChannelInfo(_ sender: Any? = nil) {
        guard let channel = liveTV.current, isWatchingChannel || ChannelStore.shared.isUnavailable(channel) else { return }
        let detail = ChannelStore.shared.isUnavailable(channel) ? "Unavailable right now" : nil
        channelBanner.show(
            channel, number: ChannelStore.shared.number(of: channel), favourite: ChannelStore.shared.isFavourite(channel), detail: detail, duration: 5)
    }

    func updateChannelControls() {
        guard isWatchingChannel else {
            controls.setChannelMode(false)
            return
        }
        let ring = liveTV.ring.isEmpty ? ChannelStore.shared.all : liveTV.ring
        let index = liveTV.current.flatMap { current in ring.firstIndex { $0.key == current.key } }
        let previous = index.flatMap { ring.isEmpty ? nil : ring[($0 - 1 + ring.count) % ring.count].name }
        let next = index.flatMap { ring.isEmpty ? nil : ring[($0 + 1) % ring.count].name }
        controls.setChannelMode(true, previousName: previous, nextName: next)
    }

    /// When the panel is closed and no channel is playing, drop the lists from memory after a
    /// minute; reopening reads them back from disk.
    func scheduleLiveTVUnload() {
        liveTVUnloadWork?.cancel()
        guard !isChannelPanelVisible, !isWatchingChannel, ChannelStore.shared.isLoaded else { return }
        let work = DispatchWorkItem { [weak self] in
            // The lists are shared by every window: keep them while any window still uses them.
            let players = NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }
            guard self != nil, !players.contains(where: { $0.isChannelPanelVisible || $0.isWatchingChannel }) else { return }
            for player in players {
                player.liveTV.ring = []
                player.channelPanel.clear()
            }
            ChannelStore.shared.unload()
            ChannelLogoLoader.shared.purgeMemory()
            PlaybackEngine.releaseFreeMemory(after: 0.5)
        }
        liveTVUnloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Empty screen "Continue watching": loads Live TV, then tunes once the lists are in.
    func continueLastChannel() {
        guard let key = ChannelStore.lastChannelKey else { return }
        let store = ChannelStore.shared
        store.loadIfNeeded()
        if let channel = store.channel(forKey: key) {
            liveTV.ring = store.recentChannels
            liveTV.ringTitle = "Recent"
            tune(to: channel)
            return
        }
        osd.show("Loading channels…", symbol: "tv", duration: 2)
        continueChannelCancellable = store.$all
            .filter { !$0.isEmpty }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let channel = store.channel(forKey: key) else { return }
                self.liveTV.ring = store.recentChannels
                self.liveTV.ringTitle = "Recent"
                self.tune(to: channel)
            }
    }

    // MARK: Number entry

    /// Typing a number tunes to that channel after a short pause, like a TV remote.
    func enterChannelDigit(_ digit: Character) {
        channelDigits.append(digit)
        if channelDigits.count > 5 {
            channelDigits = String(channelDigits.suffix(5))
        }
        osd.show("Channel \(channelDigits)", symbol: "number", duration: 1.6)
        channelDigitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let number = Int(self.channelDigits) ?? 0
            self.channelDigits = ""
            guard let channel = ChannelStore.shared.channel(number: number) else {
                self.osd.show("No channel \(number)", symbol: "exclamationmark.triangle", duration: 1.5)
                return
            }
            self.liveTV.direction = 0
            if self.liveTV.ring.isEmpty || !self.liveTV.ring.contains(where: { $0.key == channel.key }) {
                self.liveTV.ring = ChannelStore.shared.all
                self.liveTV.ringTitle = "All"
            }
            self.tune(to: channel)
        }
        channelDigitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    // MARK: Results

    func channelDidLoad() {
        guard let channel = liveTV.current, isWatchingChannel else { return }
        ChannelStore.shared.markWatched(channel)
        liveTV.skipped = 0
    }

    /// A channel failed. Picked directly: say so and stay. Reached by channel up/down: count
    /// down and move on, unless the user chooses to stay.
    func channelDidFail() {
        guard let channel = liveTV.current else { return }
        ChannelStore.shared.markUnavailable(channel)
        let number = ChannelStore.shared.number(of: channel)
        guard liveTV.direction != 0, liveTV.skipped < 25 else {
            channelBanner.show(
                channel, number: number, favourite: ChannelStore.shared.isFavourite(channel),
                detail: "Unavailable right now · free channels often go offline or are blocked in some countries", duration: 6)
            return
        }
        liveTV.skipped += 1
        countDownSkip(channel, number: number, seconds: 3)
    }

    private func countDownSkip(_ channel: Channel, number: Int?, seconds: Int) {
        channelBanner.showSkipping(channel, number: number, seconds: seconds)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.liveTV.current?.key == channel.key else { return }
            if seconds > 1 {
                self.countDownSkip(channel, number: number, seconds: seconds - 1)
            } else {
                self.channelBanner.hide()
                self.stepChannel(self.liveTV.direction)
            }
        }
        channelSkipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func cancelSkip(keepDirection: Bool = false) {
        guard channelSkipWork != nil else { return }
        channelSkipWork?.cancel()
        channelSkipWork = nil
        if !keepDirection {
            liveTV.direction = 0
            channelBanner.hide()
            if let channel = liveTV.current {
                osd.show("Staying on \(channel.name)", symbol: "hand.raised", duration: 1.5)
            }
        }
    }
}
