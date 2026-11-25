import AppKit
import Combine

@MainActor
protocol ChannelPanelDelegate: AnyObject {
    /// `ring` is the list the channel was picked from; channel up/down moves within it.
    func channelPanel(_ panel: ChannelPanel, play channel: Channel, ring: [Channel], ringTitle: String)
    func channelPanelDidClose(_ panel: ChannelPanel)
}

/// Live TV inside the player: a panel over the left of the video with Favourites, Recent and
/// All tabs, category and country filters, search, channel numbers, logos and stars.
@MainActor
final class ChannelPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Tab: Int {
        case favourites, recent, all
        var title: String {
            switch self {
            case .favourites: return "Favourites"
            case .recent: return "Recent"
            case .all: return "All"
            }
        }
    }

    weak var delegate: ChannelPanelDelegate?
    /// The channel on screen, highlighted in the list.
    var playingKey: String? {
        didSet {
            guard playingKey != oldValue else { return }
            table.reloadData()
            revealPlaying()
        }
    }

    private let store: ChannelStore
    private let tabs = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let categoryPopup = SearchableChoice()
    private let countryPopup = SearchableChoice()
    private let listsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let scopeLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let placeholder = NSStackView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderButtons = NSStackView()
    private let spinner = NSProgressIndicator()
    private var channels: [Channel] = []
    /// All tab with no category, country or search: a short category menu instead of 11,000 rows.
    private var showsAllChannels = false
    private var isBrowsing = false
    private let browseScroll = NSScrollView()
    private let browseContent = BrowseFlippedView()
    private let filters = NSStackView()
    private let backButton = NSButton(title: "‹ Categories", target: nil, action: nil)
    private var categories: [String] = []
    private var countries: [String] = []
    private var tab: Tab = .all
    private var cancellables = Set<AnyCancellable>()

    init(store: ChannelStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Layout

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        let panel = HUD.panel(cornerRadius: 14)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Live TV")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        listsButton.isBordered = false
        listsButton.pullsDown = true
        (listsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        listsButton.toolTip = "Channel lists"
        listsButton.setAccessibilityLabel("Channel lists")
        listsButton.menu?.delegate = nil
        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: self, action: #selector(closePanel(_:)))
        close.isBordered = false
        close.toolTip = "Hide Live TV (⇧⌘T)"
        let header = NSStackView(views: [title, NSView(), spinner, listsButton, close])
        header.spacing = 6
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        tabs.segmentCount = 3
        for tab in [Tab.favourites, .recent, .all] {
            tabs.setLabel(tab.title, forSegment: tab.rawValue)
        }
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = Tab.all.rawValue
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.setAccessibilityLabel("Show")

        searchField.placeholderString = "Search channels"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        for popup in [categoryPopup, countryPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 12)
            popup.onSelect = { [weak self] _ in self?.filterChanged(nil) }
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        categoryPopup.setAccessibilityLabel("Category")
        countryPopup.setAccessibilityLabel("Country")
        filters.addArrangedSubview(categoryPopup)
        filters.addArrangedSubview(countryPopup)
        filters.distribution = .fillEqually
        filters.spacing = 6

        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 11, weight: .semibold)
        backButton.contentTintColor = HUD.accent
        backButton.target = self
        backButton.action = #selector(backToCategories(_:))
        backButton.isHidden = true
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = HUD.secondaryText
        scopeLabel.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 50
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.setAccessibilityLabel("Channels")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        placeholderLabel.alignment = .center
        placeholderLabel.textColor = HUD.secondaryText
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 5
        placeholderLabel.preferredMaxLayoutWidth = 280
        let iptv = NSButton(title: "Add iptv-org — 11,000+ free channels", target: self, action: #selector(addDefault(_:)))
        iptv.bezelStyle = .rounded
        let other = NSButton(title: "Add Another List…", target: self, action: #selector(addList(_:)))
        other.bezelStyle = .rounded
        for button in [iptv, other] {
            placeholderButtons.addArrangedSubview(button)
        }
        placeholderButtons.orientation = .vertical
        placeholderButtons.spacing = 6
        let icon = NSImageView(image: NSImage(systemSymbolName: "tv.and.mediabox", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        icon.contentTintColor = HUD.secondaryText
        for view in [icon, placeholderLabel, placeholderButtons] as [NSView] {
            placeholder.addArrangedSubview(view)
        }
        placeholder.orientation = .vertical
        placeholder.spacing = 10

        browseScroll.documentView = browseContent
        browseScroll.hasVerticalScroller = true
        browseScroll.autohidesScrollers = true
        browseScroll.drawsBackground = false
        browseScroll.isHidden = true
        browseContent.translatesAutoresizingMaskIntoConstraints = false
        browseContent.widthAnchor.constraint(equalTo: browseScroll.contentView.widthAnchor).isActive = true
        let lists = NSView()
        for view in [scroll, browseScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            lists.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: lists.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: lists.trailingAnchor),
                view.topAnchor.constraint(equalTo: lists.topAnchor),
                view.bottomAnchor.constraint(equalTo: lists.bottomAnchor)
            ])
        }
        let scopeRow = NSStackView(views: [backButton, scopeLabel])
        scopeRow.spacing = 6
        let stack = NSStackView(views: [header, tabs, searchField, filters, scopeRow, lists])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: scopeRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(stack)
        panel.content.addSubview(placeholder)
        for view in [header, tabs, searchField, filters, scopeRow, lists] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: panel.content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: panel.content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: panel.content.bottomAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: lists.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: lists.centerYAnchor, constant: -20),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: lists.widthAnchor, constant: -24)
        ])

        store.$all.combineLatest(store.$favourites, store.$recent, store.$unavailable)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        store.$loadingSources.combineLatest(store.$sources)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateLoading() } }
            .store(in: &cancellables)
    }

    /// Opens on the tab that has something: Favourites if any, else All.
    /// Opens on Favourites if there are any, else Recent, else the category menu; while a
    /// channel plays, on the view that contains it.
    func prepareToShow() {
        store.loadIfNeeded()
        if playingKey == nil, categoryPopup.selectedIndex == 0, countryPopup.selectedIndex == 0, searchField.stringValue.isEmpty {
            tab = !store.favourites.isEmpty ? .favourites : !store.recent.isEmpty ? .recent : .all
            tabs.selectedSegment = tab.rawValue
            showsAllChannels = false
        }
        // Watching from the All tab: open the playing channel's category, not the menu.
        if let playingKey, tab == .all, categoryPopup.selectedIndex == 0, countryPopup.selectedIndex == 0,
            searchField.stringValue.isEmpty, !showsAllChannels, let channel = store.channel(forKey: playingKey)
        {
            reload()
            if let index = categories.firstIndex(of: channel.group) {
                categoryPopup.select(index: index + 1, notify: false)
            }
        }
        reload()
        revealPlaying()
    }

    /// Drops the channel rows (Live TV unloaded); `prepareToShow` fills them again.
    func clear() {
        channels = []
        table.reloadData()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Data

    private func tabChannels() -> [Channel] {
        switch tab {
        case .favourites: return store.favouriteChannels
        case .recent: return store.recentChannels
        case .all: return store.all
        }
    }

    func reload() {
        let base = tabChannels()
        let selectedCategory = categoryPopup.selectedIndex > 0 ? categories[safe: categoryPopup.selectedIndex - 1] : nil
        let selectedCountry = countryPopup.selectedIndex > 0 ? countries[safe: countryPopup.selectedIndex - 1] : nil

        let groupCounts = Dictionary(grouping: base, by: \.group).mapValues(\.count)
        categories = groupCounts.keys.sorted { ($0 == "Other" ? 1 : 0, $0) < ($1 == "Other" ? 1 : 0, $1) }
        categoryPopup.setOptions(
            ["All Categories"] + categories.map { "\($0)  (\(groupCounts[$0] ?? 0))" },
            selected: selectedCategory.flatMap { categories.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)

        let named = Set(base.compactMap(\.country)).map { ($0, Locale.current.localizedString(forRegionCode: $0.uppercased()) ?? $0.uppercased()) }
            .sorted { $0.1 < $1.1 }
        countries = named.map(\.0)
        countryPopup.setOptions(
            ["All Countries"] + named.map(\.1), selected: selectedCountry.flatMap { countries.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        categoryPopup.isEnabled = !categories.isEmpty
        countryPopup.isEnabled = !countries.isEmpty

        let category = categoryPopup.selectedIndex > 0 ? categories[safe: categoryPopup.selectedIndex - 1] : nil
        let country = countryPopup.selectedIndex > 0 ? countries[safe: countryPopup.selectedIndex - 1] : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let number = Int(query)
        let browsing = tab == .all && category == nil && country == nil && query.isEmpty && !showsAllChannels
        isBrowsing = browsing && !base.isEmpty
        table.isHidden = isBrowsing
        browseScroll.isHidden = !isBrowsing
        // The tiles do what the two filter boxes do; show the boxes once inside a list.
        filters.isHidden = isBrowsing
        if isBrowsing {
            rebuildBrowse(base: base, groupCounts: groupCounts)
        }
        backButton.isHidden = !(tab == .all && !browsing && query.isEmpty && (category != nil || country != nil || showsAllChannels))
        channels =
            browsing
            ? []
            : base.filter { channel in
                if let category, channel.group != category { return false }
                if let country, channel.country != country { return false }
                if query.isEmpty { return true }
                if let number, store.number(of: channel) == number { return true }
                return channel.name.lowercased().contains(query)
            }
        table.reloadData()
        revealPlaying(scroll: false)
        scopeLabel.stringValue =
            browsing
            ? "\(base.count.formatted()) channels · pick a category or country, or search"
            : scopeTitle + " · \(channels.count.formatted()) channel\(channels.count == 1 ? "" : "s")"
        updatePlaceholder()
        rebuildListsMenu()
    }

    /// Describes what channel up/down will move through.
    var scopeTitle: String {
        var parts = [tab.title]
        if categoryPopup.selectedIndex > 0, let category = categories[safe: categoryPopup.selectedIndex - 1] {
            parts.append(category)
        }
        if countryPopup.selectedIndex > 0, let country = countries[safe: countryPopup.selectedIndex - 1] {
            parts.append(Locale.current.localizedString(forRegionCode: country.uppercased()) ?? country)
        }
        if !searchField.stringValue.isEmpty {
            parts.append("“\(searchField.stringValue)”")
        }
        return parts.joined(separator: " · ")
    }

    private func updatePlaceholder() {
        let noLists = store.sources.isEmpty
        placeholderButtons.isHidden = !noLists
        if noLists {
            placeholderLabel.stringValue =
                "Watch live TV from channel lists (M3U). iptv-org has thousands of free, legal channels from around the world, or add the list from your TV provider."
        } else if store.all.isEmpty {
            placeholderLabel.stringValue = "Downloading the channel list…"
        } else if channels.isEmpty, tab == .favourites, store.favourites.isEmpty {
            placeholderLabel.stringValue = "No favourites yet. Click the star next to a channel, or press ⌘D while watching."
        } else if channels.isEmpty, tab == .recent, store.recent.isEmpty {
            placeholderLabel.stringValue = "Channels you watch appear here."
        } else if channels.isEmpty {
            placeholderLabel.stringValue = "No channels match."
        }
        placeholder.isHidden = !(noLists || (channels.isEmpty && !isBrowsing))
    }

    private func updateLoading() {
        if store.loadingSources.isEmpty {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        updatePlaceholder()
        rebuildListsMenu()
    }

    private func revealPlaying(scroll: Bool = true) {
        guard let playingKey, let row = channels.firstIndex(where: { $0.key == playingKey }) else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard scroll, let clip = table.enclosingScrollView?.contentView else { return }
        // Centre the playing channel so its neighbours (channel up/down) are visible too.
        table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: row)
        let maxY = max(0, table.bounds.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height / 2), maxY)
        clip.scroll(to: NSPoint(x: 0, y: y))
        table.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Lists menu

    private func rebuildListsMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        menu.items.first?.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Channel lists")
        for source in store.sources {
            let item = NSMenuItem(title: source.name, action: nil, keyEquivalent: "")
            let detail: String
            if store.loadingSources.contains(source.id) {
                detail = "Updating…"
            } else if let error = source.lastError {
                detail = error
            } else {
                detail =
                    "\(source.channelCount.formatted()) channels · updated \(source.lastUpdated.map { $0.formatted(.relative(presentation: .named)) } ?? "never")"
            }
            let submenu = NSMenu()
            submenu.addItem(ClosureMenuItem(detail, enabled: false) {})
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem("Update Now") { [weak self] in self?.store.refresh(source.id) })
            submenu.addItem(
                ClosureMenuItem("Rename…") { [weak self] in
                    guard let window = self?.window else { return }
                    ChannelListSheet.presentRename(on: window, source: source)
                })
            submenu.addItem(
                ClosureMenuItem("Copy List Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                })
            submenu.addItem(.separator())
            submenu.addItem(
                ClosureMenuItem("Remove List…") { [weak self] in
                    guard let window = self?.window else { return }
                    ChannelListSheet.presentRemove(on: window, source: source)
                })
            item.submenu = submenu
            menu.addItem(item)
        }
        if !store.sources.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Add Channel List…") { [weak self] in self?.addList(nil) })
        listsButton.menu = menu
    }

    // MARK: Actions

    #if DEBUG
        func debugSelectAllTab() {
            tabs.selectedSegment = Tab.all.rawValue
            tabChanged(tabs)
        }
    #endif

    @objc private func backToCategories(_ sender: Any?) {
        showsAllChannels = false
        categoryPopup.select(index: 0, notify: false)
        countryPopup.select(index: 0, notify: false)
        reload()
        table.scrollRowToVisible(0)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        tab = Tab(rawValue: sender.selectedSegment) ?? .all
        showsAllChannels = false
        categoryPopup.select(index: 0, notify: false)
        countryPopup.select(index: 0, notify: false)
        reload()
        table.scrollRowToVisible(0)
        revealPlaying()
    }

    @objc private func filterChanged(_ sender: Any?) {
        reload()
        table.scrollRowToVisible(0)
    }

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    @objc private func closePanel(_ sender: Any?) {
        delegate?.channelPanelDidClose(self)
    }

    @objc private func addDefault(_ sender: Any?) {
        guard let preset = ChannelStore.presets.first, let url = URL(string: preset.url) else { return }
        store.addSource(url: url, name: "iptv-org")
        tab = .all
        tabs.selectedSegment = tab.rawValue
        reload()
    }

    @objc func addList(_ sender: Any?) {
        guard let window else { return }
        ChannelListSheet.presentAdd(on: window) { [weak self] _ in
            guard let self else { return }
            self.tab = .all
            self.tabs.selectedSegment = self.tab.rawValue
            self.reload()
        }
    }

    @objc private func rowClicked(_ sender: NSTableView) {
        play(row: sender.clickedRow)
    }

    // MARK: Browse tiles

    private func rebuildBrowse(base: [Channel], groupCounts: [String: Int]) {
        browseContent.subviews.forEach { $0.removeFromSuperview() }
        var sections: [NSView] = []

        let countryCounts = Dictionary(grouping: base.compactMap(\.country), by: { $0 }).mapValues(\.count)
        let home = Locale.current.region?.identifier.lowercased()
        var top: [BrowseTile] = [
            BrowseTile(symbol: "square.grid.2x2", title: "All Channels", count: base.count) { [weak self] in
                self?.showsAllChannels = true
                self?.enterList()
            }
        ]
        if let home, let count = countryCounts[home] {
            top.append(
                BrowseTile(emoji: Self.flag(home), title: Self.countryName(home), count: count) { [weak self] in self?.openCountry(home) })
        }
        sections.append(Self.grid(top))

        let groups = groupCounts.keys.sorted { lhs, rhs in
            if (lhs == "Other") != (rhs == "Other") { return rhs == "Other" }
            return (groupCounts[lhs] ?? 0, rhs) > (groupCounts[rhs] ?? 0, lhs)
        }
        sections.append(Self.sectionLabel("Categories"))
        sections.append(
            Self.grid(
                groups.map { group in
                    BrowseTile(symbol: Self.symbol(forGroup: group), title: group, count: groupCounts[group] ?? 0) { [weak self] in
                        self?.openCategory(group)
                    }
                }))

        let countries = countryCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12).map(\.key)
        if !countries.isEmpty {
            sections.append(Self.sectionLabel("Countries"))
            var tiles = countries.map { code in
                BrowseTile(emoji: Self.flag(code), title: Self.countryName(code), count: countryCounts[code] ?? 0) { [weak self] in
                    self?.openCountry(code)
                }
            }
            if countryCounts.count > countries.count {
                tiles.append(
                    BrowseTile(symbol: "globe", title: "More countries…", count: countryCounts.count) { [weak self] in
                        guard let self else { return }
                        self.filters.isHidden = false
                        self.window?.makeFirstResponder(self.countryPopup)
                    })
            }
            sections.append(Self.grid(tiles))
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        browseContent.addSubview(stack)
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: browseContent.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: browseContent.trailingAnchor),
            stack.topAnchor.constraint(equalTo: browseContent.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: browseContent.bottomAnchor, constant: -8)
        ])
    }

    private func openCategory(_ group: String) {
        guard let index = categories.firstIndex(of: group) else { return }
        categoryPopup.select(index: index + 1, notify: false)
        enterList()
    }

    private func openCountry(_ code: String) {
        guard let index = countries.firstIndex(of: code) else { return }
        countryPopup.select(index: index + 1, notify: false)
        enterList()
    }

    private func enterList() {
        reload()
        table.scrollRowToVisible(0)
        revealPlaying()
    }

    private static func grid(_ tiles: [BrowseTile]) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        var index = 0
        while index < tiles.count {
            let second: NSView = index + 1 < tiles.count ? tiles[index + 1] : NSView()
            grid.addRow(with: [tiles[index], second])
            index += 2
        }
        for column in 0..<2 {
            grid.column(at: column).xPlacement = .fill
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Equal columns.
        if grid.numberOfRows > 0 {
            let first = grid.cell(atColumnIndex: 0, rowIndex: 0).contentView
            let other = grid.cell(atColumnIndex: 1, rowIndex: 0).contentView
            if let first, let other {
                first.widthAnchor.constraint(equalTo: other.widthAnchor).isActive = true
            }
        }
        return grid
    }

    private static func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = HUD.secondaryText
        let holder = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: holder.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        return holder
    }

    static func flag(_ code: String) -> String {
        guard code.count == 2 else { return "🌐" }
        return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    }

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, table.selectedRow >= 0 {
            play(row: table.selectedRow)
        } else if event.keyCode == 53 {
            closePanel(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func play(row: Int) {
        guard channels.indices.contains(row) else { return }
        delegate?.channelPanel(self, play: channels[row], ring: channels, ringTitle: scopeTitle)
    }

    fileprivate func toggleFavourite(_ channel: Channel) {
        store.toggleFavourite(channel)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { isBrowsing ? 0 : channels.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ChannelRowBackground.identifier, owner: self) as? ChannelRowBackground ?? ChannelRowBackground()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChannelRow.identifier, owner: self) as? ChannelRow ?? ChannelRow()
        let channel = channels[row]
        cell.show(
            channel, number: store.number(of: channel), favourite: store.isFavourite(channel), unavailable: store.isUnavailable(channel),
            playing: channel.key == playingKey)
        cell.onStar = { [weak self] in self?.toggleFavourite(channel) }
        return cell
    }
}

extension ChannelPanel {
    static func symbol(forGroup group: String) -> String {
        switch group.lowercased() {
        case "news": return "newspaper"
        case "movies": return "film"
        case "music": return "music.note"
        case "sports": return "sportscourt"
        case "kids", "animation": return "teddybear"
        case "entertainment", "comedy": return "theatermasks"
        case "documentary", "science", "education": return "graduationcap"
        case "religious": return "building.columns"
        case "business": return "chart.line.uptrend.xyaxis"
        case "lifestyle", "cooking", "travel": return "leaf"
        case "weather": return "cloud.sun"
        case "shop": return "bag"
        case "auto": return "car"
        case "family": return "figure.2.and.child.holdinghands"
        case "legislative": return "building.2"
        case "culture", "classic": return "theatermask.and.paintbrush"
        case "outdoor": return "mountain.2"
        case "series": return "rectangle.stack"
        default: return "tv"
        }
    }
}

/// A browse tile: icon or flag, name and channel count; highlights on hover.
@MainActor
private final class BrowseTile: NSView {
    private let action: () -> Void
    private var hovering = false {
        didSet { layer?.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 0.14 : 0.07).cgColor }
    }
    private var tracking: NSTrackingArea?

    convenience init(symbol: String, title: String, count: Int, action: @escaping () -> Void) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.contentTintColor = HUD.accent
        self.init(icon: icon, title: title, count: count, action: action)
    }

    convenience init(emoji: String, title: String, count: Int, action: @escaping () -> Void) {
        let icon = NSTextField(labelWithString: emoji)
        icon.font = .systemFont(ofSize: 16)
        self.init(icon: icon, title: title, count: count, action: action)
    }

    private init(icon: NSView, title: String, count: Int, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let countLabel = NSTextField(labelWithString: count.formatted())
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = HUD.secondaryText
        let text = NSStackView(views: [titleLabel, countLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [icon, text])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            icon.widthAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(count) channels")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

/// Lays the browse tiles out from the top.
private final class BrowseFlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension ChannelPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard channels.indices.contains(row) else { return }
        let channel = channels[row]
        menu.addItem(ClosureMenuItem("Watch") { [weak self] in self?.play(row: row) })
        menu.addItem(
            ClosureMenuItem(store.isFavourite(channel) ? "Remove from Favourites" : "Add to Favourites") { [weak self] in
                self?.toggleFavourite(channel)
            })
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem("Copy Stream Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.url.absoluteString, forType: .string)
            })
    }
}

/// Rounded accent highlight for the playing / selected row; a soft one on hover.
@MainActor
private final class ChannelRowBackground: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelRowBackground")
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 1)
        HUD.accent.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// One channel row: number, logo, name, category · country and a clickable star.
@MainActor
private final class ChannelRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelRow")
    var onStar: (() -> Void)?

    private let numberLabel = NSTextField(labelWithString: "")
    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let star = NSButton()
    private let playingIcon = NSImageView()
    private var logoURL: URL?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        numberLabel.textColor = HUD.secondaryText
        numberLabel.alignment = .right
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 5
        logo.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = HUD.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        star.isBordered = false
        star.imagePosition = .imageOnly
        star.target = self
        star.action = #selector(starClicked)
        playingIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing")
        playingIcon.contentTintColor = HUD.accent
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [numberLabel, logo, text, playingIcon, star] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            numberLabel.widthAnchor.constraint(equalToConstant: 34),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 48),
            logo.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: playingIcon.leadingAnchor, constant: -6),
            playingIcon.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -6),
            playingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func starClicked() {
        onStar?()
    }

    func show(_ channel: Channel, number: Int?, favourite: Bool, unavailable: Bool, playing: Bool) {
        numberLabel.stringValue = number.map(String.init) ?? ""
        nameLabel.stringValue = channel.name
        detailLabel.stringValue =
            unavailable ? "Unavailable right now" : [channel.group, channel.countryName].compactMap { $0 }.joined(separator: " · ")
        for view in [numberLabel, logo, nameLabel] as [NSView] {
            view.alphaValue = unavailable ? 0.45 : 1
        }
        detailLabel.textColor = unavailable ? .systemOrange.withAlphaComponent(0.8) : HUD.secondaryText
        playingIcon.isHidden = !playing
        star.image = NSImage(
            systemSymbolName: favourite ? "star.fill" : "star", accessibilityDescription: favourite ? "Remove from favourites" : "Add to favourites")
        star.contentTintColor = favourite ? .systemYellow : HUD.secondaryText
        star.toolTip = favourite ? "Remove from Favourites" : "Add to Favourites"
        setAccessibilityLabel(
            "\(number.map { "Channel \($0), " } ?? "")\(channel.name), \(detailLabel.stringValue)\(favourite ? ", favourite" : "")\(playing ? ", playing" : "")"
        )

        if let old = logoURL, old != channel.logo {
            ChannelLogoLoader.shared.cancel(old)
        }
        logoURL = channel.logo
        let placeholder = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        guard let url = channel.logo else {
            logo.image = placeholder
            logo.contentTintColor = HUD.secondaryText
            return
        }
        if let image = ChannelLogoLoader.shared.cached(url) {
            logo.image = image
            return
        }
        logo.image = placeholder
        logo.contentTintColor = HUD.secondaryText
        ChannelLogoLoader.shared.load(url) { [weak self] image in
            guard let self, self.logoURL == url, let image else { return }
            self.logo.image = image
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
