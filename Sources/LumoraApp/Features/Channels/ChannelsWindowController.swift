import AppKit
import Combine

/// Window › Channels (⇧⌘T): live TV and radio from channel lists (M3U), with categories,
/// countries, search, favourites and recently watched.
@MainActor
final class ChannelsWindowController: NSWindowController {
    static let shared = ChannelsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Channels"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        contentViewController = ChannelsViewController(store: ChannelStore.shared)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.setFrameAutosaveName("Channels")
        if window.frame.width < 720 {
            window.setContentSize(NSSize(width: 980, height: 640))
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        ChannelStore.shared.loadIfNeeded()
        super.showWindow(sender)
    }

    /// Shows the window with a list just added (or being downloaded) selected.
    func show(source id: UUID) {
        showWindow(nil)
        (contentViewController as? ChannelsViewController)?.select(.source(id))
    }

    func promptForList() {
        showWindow(nil)
        (contentViewController as? ChannelsViewController)?.addList(nil)
    }
}

private enum ChannelScope: Hashable {
    case favourites
    case recent
    case all
    case category(String)
    case source(UUID)
}

private enum SidebarRow {
    case header(String)
    case item(ChannelScope, title: String, symbol: String, count: Int)
}

@MainActor
private final class ChannelsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let store: ChannelStore
    private let sidebar = NSTableView()
    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let countryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let placeholder = NSStackView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let presetStack = NSStackView()

    private var sidebarRows: [SidebarRow] = []
    private var scope: ChannelScope = .all
    private var channels: [Channel] = []
    private var countries: [String] = []
    private var cancellables = Set<AnyCancellable>()

    init(store: ChannelStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 640))

        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        sidebar.addTableColumn(sidebarColumn)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 28
        sidebar.backgroundColor = .clear
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Channel categories")
        let sidebarMenu = NSMenu()
        sidebarMenu.delegate = self
        sidebar.menu = sidebarMenu
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Channel List") ?? NSImage(), target: self,
            action: #selector(addList(_:)))
        addButton.bezelStyle = .accessoryBarAction
        addButton.title = " Add List"
        addButton.imagePosition = .imageLeading
        addButton.toolTip = "Add a channel list (M3U link or file)"

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        searchField.placeholderString = "Search channels"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        countryPopup.target = self
        countryPopup.action = #selector(countryChanged(_:))
        countryPopup.setAccessibilityLabel("Country")
        let heading = NSStackView(views: [titleLabel, countLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 1
        let header = NSStackView(views: [heading, NSView(), countryPopup, searchField])
        header.alignment = .centerY
        header.spacing = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(playClicked(_:))
        table.setAccessibilityLabel("Channels")
        let channelMenu = NSMenu()
        channelMenu.delegate = self
        table.menu = channelMenu
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel])
        footer.spacing = 6

        buildPlaceholder()

        let content = NSView()
        for view in [sidebarBackground, sidebarScroll, addButton, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for view in [header, tableScroll, placeholder, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 230),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            sidebarScroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            addButton.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            content.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            tableScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tableScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: tableScroll.widthAnchor, constant: -60),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        view = root

        store.$sources.combineLatest(store.$channelsBySource, store.$favourites, store.$recent)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reloadAll() }
            .store(in: &cancellables)
        store.$loadingSources
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }
            .store(in: &cancellables)
        reloadAll()
    }

    private func buildPlaceholder() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "tv.and.mediabox", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 4
        placeholderLabel.preferredMaxLayoutWidth = 420
        let iptv = NSButton(title: "Add iptv-org — 11,000+ free channels", target: self, action: #selector(addDefaultList(_:)))
        iptv.bezelStyle = .rounded
        iptv.keyEquivalent = "\r"
        let other = NSButton(title: "Add Another List…", target: self, action: #selector(addList(_:)))
        other.bezelStyle = .rounded
        for view in [iptv, other] {
            presetStack.addArrangedSubview(view)
        }
        presetStack.orientation = .vertical
        presetStack.spacing = 8
        for view in [icon, placeholderLabel, presetStack] as [NSView] {
            placeholder.addArrangedSubview(view)
        }
        placeholder.orientation = .vertical
        placeholder.spacing = 12
    }

    // MARK: Data

    private func reloadAll() {
        rebuildSidebar()
        reloadChannels()
        updateStatus()
    }

    private func rebuildSidebar() {
        let all = store.allChannels
        var rows: [SidebarRow] = [
            .header("Watch"),
            .item(.favourites, title: "Favourites", symbol: "star", count: store.favourites.count),
            .item(.recent, title: "Recently Watched", symbol: "clock", count: store.recent.count),
            .item(.all, title: "All Channels", symbol: "square.grid.2x2", count: all.count)
        ]
        let groups = Dictionary(grouping: all, by: \.group).mapValues(\.count)
        if !groups.isEmpty {
            rows.append(.header("Categories"))
            let sorted = groups.keys.sorted { ($0 == "Other" ? 1 : 0, $0) < ($1 == "Other" ? 1 : 0, $1) }
            for group in sorted {
                rows.append(.item(.category(group), title: group, symbol: Self.symbol(forGroup: group), count: groups[group] ?? 0))
            }
        }
        if !store.sources.isEmpty {
            rows.append(.header("Lists"))
            for source in store.sources {
                rows.append(
                    .item(.source(source.id), title: source.name, symbol: "list.bullet.rectangle", count: store.channelsBySource[source.id]?.count ?? 0))
            }
        }
        sidebarRows = rows
        sidebar.reloadData()
        if let index = rows.firstIndex(where: { if case .item(let s, _, _, _) = $0 { return s == scope } else { return false } }) {
            sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            scope = .all
            if let index = rows.firstIndex(where: { if case .item(.all, _, _, _) = $0 { return true } else { return false } }) {
                sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
    }

    private static func symbol(forGroup group: String) -> String {
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
        default: return "tv"
        }
    }

    private func scopedChannels() -> [Channel] {
        switch scope {
        case .favourites:
            return store.allChannels.filter { store.favourites.contains($0.id) }
        case .recent:
            return store.recent.compactMap { store.channel(withID: $0) }
        case .all:
            return store.allChannels
        case .category(let group):
            return store.allChannels.filter { $0.group == group }
        case .source(let id):
            return store.channelsBySource[id] ?? []
        }
    }

    private func reloadChannels() {
        let scoped = scopedChannels()
        // Country choices come from the current scope so the menu stays short.
        let codes = Set(scoped.compactMap(\.country))
        let named = codes.map { ($0, Locale.current.localizedString(forRegionCode: $0.uppercased()) ?? $0.uppercased()) }.sorted { $0.1 < $1.1 }
        let selectedCountry = countryPopup.indexOfSelectedItem > 0 ? countries[safe: countryPopup.indexOfSelectedItem - 1] : nil
        countries = named.map(\.0)
        countryPopup.removeAllItems()
        countryPopup.addItem(withTitle: "All Countries")
        countryPopup.addItems(withTitles: named.map(\.1))
        if let selectedCountry, let index = countries.firstIndex(of: selectedCountry) {
            countryPopup.selectItem(at: index + 1)
        }
        countryPopup.isHidden = countries.isEmpty

        let country = countryPopup.indexOfSelectedItem > 0 ? countries[safe: countryPopup.indexOfSelectedItem - 1] : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        channels = scoped.filter { channel in
            if let country, channel.country != country { return false }
            return query.isEmpty || channel.name.lowercased().contains(query) || channel.group.lowercased().contains(query)
        }
        table.reloadData()

        titleLabel.stringValue = scopeTitle
        countLabel.stringValue =
            channels.count == scoped.count
            ? "\(scoped.count.formatted()) channels" : "\(channels.count.formatted()) of \(scoped.count.formatted()) channels"
        countLabel.isHidden = scoped.isEmpty
        updatePlaceholder(scopedEmpty: scoped.isEmpty)
    }

    private var scopeTitle: String {
        switch scope {
        case .favourites: return "Favourites"
        case .recent: return "Recently Watched"
        case .all: return "All Channels"
        case .category(let group): return group
        case .source(let id): return store.sources.first { $0.id == id }?.name ?? "Channels"
        }
    }

    private func updatePlaceholder(scopedEmpty: Bool) {
        let noLists = store.sources.isEmpty
        presetStack.isHidden = !noLists
        if noLists {
            placeholderLabel.stringValue =
                "Watch live TV from channel lists (M3U). iptv-org lists thousands of free, legal channels from around the world. You can also add a list from your TV provider."
        } else if case .favourites = scope, scopedEmpty {
            placeholderLabel.stringValue = "Right-click a channel and choose Add to Favourites to keep it here."
        } else if case .recent = scope, scopedEmpty {
            placeholderLabel.stringValue = "Channels you watch appear here."
        } else if scopedEmpty, !store.loadingSources.isEmpty {
            placeholderLabel.stringValue = "Downloading the channel list…"
        } else if channels.isEmpty {
            placeholderLabel.stringValue = scopedEmpty ? "No channels here." : "No channels match “\(searchField.stringValue)”."
        }
        placeholder.isHidden = !(noLists || channels.isEmpty)
    }

    private func updateStatus() {
        let loading = store.sources.filter { store.loadingSources.contains($0.id) }
        if !loading.isEmpty {
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Updating \(loading.map(\.name).joined(separator: ", "))…"
            return
        }
        spinner.stopAnimation(nil)
        if let failed = store.sources.first(where: { $0.lastError != nil }) {
            statusLabel.stringValue = "\(failed.name): \(failed.lastError ?? "")"
        } else if let newest = store.sources.compactMap(\.lastUpdated).max() {
            statusLabel.stringValue =
                "Lists updated \(newest.formatted(.relative(presentation: .named))). Many free channels go offline or are blocked in some countries."
        } else {
            statusLabel.stringValue = ""
        }
    }

    func select(_ newScope: ChannelScope) {
        _ = view
        scope = newScope
        rebuildSidebar()
        reloadChannels()
    }

    @objc private func countryChanged(_ sender: Any?) {
        reloadChannels()
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadChannels()
    }

    // MARK: Adding lists

    @objc private func addDefaultList(_ sender: Any?) {
        guard let preset = ChannelStore.presets.first, let url = URL(string: preset.url) else { return }
        select(.source(store.addSource(url: url, name: "iptv-org")))
    }

    @objc func addList(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add a Channel List"
        alert.informativeText = "Choose a free list from iptv-org, or paste the M3U link from your TV provider."
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ChannelStore.presets.map(\.name) + ["Other link…"])
        let field = NSTextField()
        field.placeholderString = "https://example.com/channels.m3u"
        field.isEnabled = false
        let chooseFile = NSButton(title: "Choose File…", target: nil, action: nil)
        chooseFile.bezelStyle = .rounded
        let stack = NSStackView(views: [popup, field, chooseFile])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 92)
        field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        popup.widthAnchor.constraint(equalToConstant: 380).isActive = true
        let toggle = PopupToggle { [weak field] index in
            let custom = index == ChannelStore.presets.count
            field?.isEnabled = custom
            if custom { field?.window?.makeFirstResponder(field) }
        }
        popup.target = toggle
        popup.action = #selector(PopupToggle.changed(_:))
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        chooseFile.target = toggle
        chooseFile.action = #selector(PopupToggle.chooseFile(_:))
        toggle.onFile = { [weak self] url in
            window.endSheet(alert.window)
            guard let self else { return }
            self.select(.source(self.store.addSource(url: url)))
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            _ = toggle
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                let index = popup.indexOfSelectedItem
                if index < ChannelStore.presets.count, let url = URL(string: ChannelStore.presets[index].url) {
                    self.select(
                        .source(self.store.addSource(url: url, name: ChannelStore.presets[index].name.replacingOccurrences(of: " (iptv-org)", with: ""))))
                } else if let url = MainWindowController.normalizedLink(field.stringValue.trimmingCharacters(in: .whitespaces)) {
                    self.select(.source(self.store.addSource(url: url)))
                }
            }
        }
    }

    // MARK: Playing

    @objc private func playClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        play(row: sender.clickedRow)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, table.selectedRow >= 0, view.window?.firstResponder === table {
            play(row: table.selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Plays a channel; the channels in view become the playlist so ⌘← / ⌘→ switch channels.
    private func play(row: Int) {
        guard channels.indices.contains(row) else { return }
        let window = 300
        let start = max(0, row - window)
        let end = min(channels.count, row + window + 1)
        let items = channels[start..<end].map(\.playbackItem)
        (NSApp.delegate as? AppDelegate)?.playChannels(items, startAt: row - start)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table.menu {
            let row = table.clickedRow
            guard channels.indices.contains(row) else { return }
            let channel = channels[row]
            menu.addItem(ClosureMenuItem("Play") { [weak self] in self?.play(row: row) })
            menu.addItem(
                ClosureMenuItem(store.isFavourite(channel) ? "Remove from Favourites" : "Add to Favourites") { [weak self] in
                    self?.store.toggleFavourite(channel)
                })
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem("Copy Stream Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(channel.url.absoluteString, forType: .string)
                })
        } else if menu === sidebar.menu {
            let row = sidebar.clickedRow
            guard sidebarRows.indices.contains(row), case .item(.source(let id), let name, _, _) = sidebarRows[row] else { return }
            menu.addItem(ClosureMenuItem("Update Now") { [weak self] in self?.store.refresh(id) })
            menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.rename(id, current: name) })
            if let source = store.sources.first(where: { $0.id == id }) {
                menu.addItem(
                    ClosureMenuItem("Copy List Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                    })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove List…") { [weak self] in self?.confirmRemove(id, name: name) })
        }
    }

    private func rename(_ id: UUID, current: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename List"
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.store.rename(id, to: field.stringValue.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private func confirmRemove(_ id: UUID, name: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its channels disappear from Lumora. Favourites from it come back if you add the list again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.store.removeSource(id) }
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? sidebarRows.count : channels.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebar, case .header = sidebarRows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === sidebar else { return true }
        if case .header = sidebarRows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === sidebar, sidebarRows.indices.contains(sidebar.selectedRow),
            case .item(let newScope, _, _, _) = sidebarRows[sidebar.selectedRow], newScope != scope
        else { return }
        scope = newScope
        reloadChannels()
        table.scrollRowToVisible(0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            switch sidebarRows[row] {
            case .header(let title):
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                return label
            case .item(_, let title, let symbol, let count):
                let cell = NSTableCellView()
                let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = .controlAccentColor
                let label = NSTextField(labelWithString: title)
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let badge = NSTextField(labelWithString: count > 0 ? count.formatted() : "")
                badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                badge.textColor = .secondaryLabelColor
                let stack = NSStackView(views: [icon, label, NSView(), badge])
                stack.spacing = 6
                stack.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 18)
                ])
                return cell
            }
        }
        let cell = tableView.makeView(withIdentifier: ChannelCell.identifier, owner: self) as? ChannelCell ?? ChannelCell()
        let channel = channels[row]
        cell.show(channel, favourite: store.isFavourite(channel))
        return cell
    }
}

/// Target object for the Add List sheet's controls.
@MainActor
private final class PopupToggle: NSObject {
    let onChange: (Int) -> Void
    var onFile: ((URL) -> Void)?

    init(onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }

    @objc func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.m3uPlaylist, .playlist].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.onFile?(url) }
        }
    }
}

/// One channel: logo, name, category and country, and a star for favourites.
@MainActor
private final class ChannelCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelCell")

    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let star = NSImageView()
    private var logoURL: URL?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.wantsLayer = true
        logo.layer?.cornerRadius = 6
        logo.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favourite")
        star.contentTintColor = .systemYellow
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [logo, text, star] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 52),
            logo.heightAnchor.constraint(equalToConstant: 36),
            text.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -10),
            star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            star.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ channel: Channel, favourite: Bool) {
        nameLabel.stringValue = channel.name
        detailLabel.stringValue = [channel.group, channel.countryName].compactMap { $0 }.joined(separator: " · ")
        star.isHidden = !favourite
        setAccessibilityLabel("\(channel.name), \(detailLabel.stringValue)\(favourite ? ", favourite" : "")")
        if let old = logoURL, old != channel.logo {
            ChannelLogoLoader.shared.cancel(old)
        }
        logoURL = channel.logo
        let placeholder = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        guard let url = channel.logo else {
            logo.image = placeholder
            logo.contentTintColor = .tertiaryLabelColor
            return
        }
        if let image = ChannelLogoLoader.shared.cached(url) {
            logo.image = image
            return
        }
        logo.image = placeholder
        logo.contentTintColor = .tertiaryLabelColor
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
