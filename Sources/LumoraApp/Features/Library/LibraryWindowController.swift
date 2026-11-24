import AppKit
import Combine

/// Window › Library (⇧⌘L): everything played, newest first, with progress, filters, search
/// and a context menu (play, show in Finder, mark watched, remove).
@MainActor
final class LibraryWindowController: NSWindowController {
    static let shared = LibraryWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Library"
        window.minSize = NSSize(width: 520, height: 320)
        super.init(window: window)
        contentViewController = LibraryViewController(library: LibraryStore.shared)
        // The view controller's view has a fixed starting size; restore the user's size if saved.
        window.setContentSize(NSSize(width: 760, height: 540))
        window.setFrameAutosaveName("Library")
        if window.frame.width < 520 || window.frame.height < 320 {
            window.setContentSize(NSSize(width: 760, height: 540))
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private enum Filter: Int, CaseIterable {
        case all, inProgress, watched
        var title: String {
            switch self {
            case .all: return "All"
            case .inProgress: return "In Progress"
            case .watched: return "Watched"
            }
        }
    }

    private let library: LibraryStore
    private let tableView = NSTableView()
    private let filterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var records: [LibraryRecord] = []
    private var cancellable: AnyCancellable?
    private var filter: Filter = .all

    init(library: LibraryStore) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 540))

        filterControl.segmentCount = Filter.allCases.count
        for filter in Filter.allCases {
            filterControl.setLabel(filter.title, forSegment: filter.rawValue)
            filterControl.setWidth(0, forSegment: filter.rawValue)
        }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.setAccessibilityLabel("Show")

        searchField.placeholderString = "Search library"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let header = NSStackView(views: [filterControl, NSView(), searchField])
        header.orientation = .horizontal
        header.spacing = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 54
        tableView.usesAutomaticRowHeights = false
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(playClicked(_:))
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.setAccessibilityLabel("Library items")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        countLabel.font = .systemFont(ofSize: 11.5)
        countLabel.textColor = .secondaryLabelColor
        let clear = NSButton(title: "Clear History…", target: self, action: #selector(clearHistory(_:)))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        let footer = NSStackView(views: [countLabel, NSView(), clear])
        footer.orientation = .horizontal

        for view in [header, scroll, emptyLabel, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }

    /// Only listens for library changes while the window is open (progress is saved every few
    /// seconds during playback).
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        cancellable = library.$records
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        cancellable = nil
    }

    private func reload() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let all = library.recent(limit: 500)
        records = all.filter { record in
            switch filter {
            case .all: break
            case .inProgress: if record.watched || record.resumeTime < 5 { return false }
            case .watched: if !record.watched { return false }
            }
            return query.isEmpty || record.title.lowercased().contains(query) || record.url.absoluteString.lowercased().contains(query)
        }
        tableView.reloadData()
        countLabel.stringValue = all.isEmpty ? "" : "\(records.count) of \(all.count) item\(all.count == 1 ? "" : "s")"
        if all.isEmpty {
            emptyLabel.stringValue = "Videos and songs you play appear here, with where you left off."
        } else {
            emptyLabel.stringValue = query.isEmpty ? "Nothing in \(filter.title)." : "No items match “\(searchField.stringValue)”."
        }
        emptyLabel.isHidden = !records.isEmpty
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        filter = Filter(rawValue: sender.selectedSegment) ?? .all
        reload()
    }

    func controlTextDidChange(_ notification: Notification) {
        reload()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: LibraryCell.identifier, owner: self) as? LibraryCell ?? LibraryCell()
        cell.show(records[row])
        return cell
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: play(rows: tableView.selectedRowIndexes)
        case 51, 117: remove(rows: tableView.selectedRowIndexes)
        default: super.keyDown(with: event)
        }
    }

    @objc private func playClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        play(rows: IndexSet(integer: sender.clickedRow))
    }

    private func play(rows: IndexSet) {
        let urls = rows.compactMap { records.indices.contains($0) ? records[$0].url : nil }
        guard !urls.isEmpty else { return }
        // Opens in the active player window, creating one if every player window was closed.
        (NSApp.delegate as? AppDelegate)?.openInActivePlayer(urls)
    }

    private func remove(rows: IndexSet) {
        let urls = rows.compactMap { records.indices.contains($0) ? records[$0].url : nil }
        urls.forEach { library.remove(url: $0) }
    }

    // MARK: Context menu

    /// Acts on the right-clicked row, or the whole selection when that row is part of it.
    private var menuRows: IndexSet {
        let clicked = tableView.clickedRow
        guard clicked >= 0 else { return tableView.selectedRowIndexes }
        return tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = menuRows
        let selected = rows.compactMap { records.indices.contains($0) ? records[$0] : nil }
        guard !selected.isEmpty else { return }
        menu.addItem(ClosureMenuItem(selected.count == 1 ? "Play" : "Play \(selected.count) Items") { [weak self] in self?.play(rows: rows) })
        let files = selected.filter { $0.url.isFileURL }
        if !files.isEmpty {
            menu.addItem(ClosureMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url)) })
        }
        if selected.count == 1, let link = selected.first, !link.url.isFileURL {
            menu.addItem(
                ClosureMenuItem("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                })
        }
        menu.addItem(.separator())
        let allWatched = selected.allSatisfy(\.watched)
        menu.addItem(
            ClosureMenuItem(allWatched ? "Mark as Unwatched" : "Mark as Watched") { [weak self] in
                selected.forEach { self?.library.setWatched(url: $0.url, watched: !allWatched) }
            })
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(selected.count == 1 ? "Remove from Library" : "Remove \(selected.count) Items") { [weak self] in self?.remove(rows: rows) })
    }

    @objc private func clearHistory(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear the whole library?"
        alert.informativeText = "Lumora forgets every item, where you left off and your bookmarks. Your files aren't touched."
        alert.addButton(withTitle: "Clear Library")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.library.removeAll() }
        }
    }
}

/// One library row: kind icon, title, where it's from and when it was played, and progress.
@MainActor
private final class LibraryCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryCell")

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let right = NSStackView(views: [progressLabel, progress])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 4
        for view in [icon, text, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 120),
            progressLabel.widthAnchor.constraint(equalToConstant: 140)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ record: LibraryRecord) {
        titleLabel.stringValue = record.title
        let source: String
        if record.url.isFileURL {
            source = record.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        } else {
            source = record.url.host ?? record.url.absoluteString
        }
        detailLabel.stringValue = "\(source) · \(Self.relative.localizedString(for: record.lastPlayed, relativeTo: Date()))"

        let symbol: String
        let tint: NSColor
        if record.watched {
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
        } else if record.url.isFileURL {
            symbol = "play.circle"
            tint = .controlAccentColor
        } else {
            symbol = "globe"
            tint = .secondaryLabelColor
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint

        if record.watched {
            progress.isHidden = true
            progressLabel.stringValue = "Watched"
        } else if record.duration > 0 {
            let fraction = min(max(record.resumeTime / record.duration, 0), 1)
            progress.isHidden = false
            progress.doubleValue = fraction
            let left = max(0, record.duration - record.resumeTime)
            progressLabel.stringValue = record.resumeTime < 5 ? TimeFormatter.string(record.duration) : "\(TimeFormatter.string(left)) left"
        } else {
            progress.isHidden = true
            progressLabel.stringValue = ""
        }
        setAccessibilityLabel("\(record.title), \(progressLabel.stringValue), \(detailLabel.stringValue)")
    }
}
