import AppKit

@MainActor
protocol PlaylistSidebarDelegate: AnyObject {
    func playlistSidebar(_ sidebar: PlaylistSidebar, didSelect index: Int)
    func playlistSidebarDidRequestAdd(_ sidebar: PlaylistSidebar)
    func playlistSidebarDidRequestClear(_ sidebar: PlaylistSidebar)
    func playlistSidebar(_ sidebar: PlaylistSidebar, didRequestRemove index: Int)
}

@MainActor
final class PlaylistSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: PlaylistSidebarDelegate?

    private let store: PlaylistStore
    private let tableView = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "Playlist")
    private let addButton: NSButton
    private let removeButton: NSButton
    private let clearButton: NSButton
    private let saveButton: NSButton
    private let summaryLabel = NSTextField(labelWithString: "")
    /// Known length of an item (from the library, or the engine for the playing one).
    var durationFor: ((PlaybackItem) -> TimeInterval?)?
    private static let rowType = NSPasteboard.PasteboardType("com.lumora.playlist-row")

    init(store: PlaylistStore) {
        self.store = store
        addButton = PlaylistSidebar.makeButton(symbol: "plus", tooltip: "Add media")
        removeButton = PlaylistSidebar.makeButton(symbol: "minus", tooltip: "Remove selected")
        clearButton = PlaylistSidebar.makeButton(symbol: "trash", tooltip: "Clear playlist")
        saveButton = PlaylistSidebar.makeButton(symbol: "square.and.arrow.down", tooltip: "Save playlist as M3U")
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        appearance = NSAppearance(named: .vibrantDark)
        let panel = HUD.panel(cornerRadius: 14)
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = "Media"
        column.width = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setAccessibilityLabel("Playlist")
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickRow(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = HUD.secondaryText
        for button in [addButton, removeButton, clearButton, saveButton] {
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.target = self
            button.action = #selector(buttonTapped(_:))
        }

        let header = NSStackView(views: [titleLabel, NSView(), addButton, removeButton, saveButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 4

        let stack = NSStackView(views: [header, summaryLabel, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        for view in [header, summaryLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        reload()
    }

    /// The playing item is marked by its highlight and icon, not the table selection, so
    /// "Remove selected" only ever removes what the user picked.
    func reload() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection.filteredIndexSet { $0 < store.items.count }, byExtendingSelection: false)
        let count = store.items.count
        let total = store.items.compactMap { durationFor?($0) }.reduce(0, +)
        var summary = count == 1 ? "1 item" : "\(count) items"
        if total > 0 {
            summary += " · \(TimeFormatter.string(total))"
        }
        summaryLabel.stringValue = count == 0 ? "Empty — drop files here or click +" : summary
        saveButton.isEnabled = count > 0
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = PlaylistRowBackground()
        view.isCurrent = row == store.currentIndex
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PlaylistRow.identifier, owner: self) as? PlaylistRow ?? PlaylistRow()
        let item = store.items[row]
        cell.show(item, number: row + 1, playing: row == store.currentIndex, duration: durationFor?(item))
        return cell
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType), let source = Int(value) else {
            return false
        }
        // Dropping below the item's own position shifts the target up by one.
        let destination = min(source < row ? row - 1 : row, store.items.count - 1)
        guard destination != source else { return false }
        store.move(from: source, to: destination)
        reload()
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, tableView.selectedRow >= 0 {
            delegate?.playlistSidebar(self, didRequestRemove: tableView.selectedRow)
        } else if event.keyCode == 36 || event.keyCode == 76, tableView.selectedRow >= 0 {
            delegate?.playlistSidebar(self, didSelect: tableView.selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Save

    /// Writes the playlist as an extended M3U (titles and known lengths included).
    private func savePlaylist() {
        guard let window, !store.items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Playlist.m3u"
        panel.allowedContentTypes = [.m3uPlaylist]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                var lines = ["#EXTM3U"]
                for item in self.store.items {
                    let length = self.durationFor?(item).map { Int($0.rounded()) } ?? -1
                    lines.append("#EXTINF:\(length),\(item.title.replacingOccurrences(of: "\n", with: " "))")
                    lines.append(item.url.isFileURL ? item.url.path : item.url.absoluteString)
                }
                do {
                    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    private static func makeButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
            target: nil,
            action: nil
        )
        button.toolTip = tooltip
        button.imagePosition = .imageOnly
        return button
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        if sender == addButton {
            delegate?.playlistSidebarDidRequestAdd(self)
        } else if sender == clearButton {
            delegate?.playlistSidebarDidRequestClear(self)
        } else if sender == saveButton {
            savePlaylist()
        } else if sender == removeButton {
            let row = tableView.selectedRow
            if row >= 0 {
                delegate?.playlistSidebar(self, didRequestRemove: row)
            }
        }
    }

    @objc private func doubleClickRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        delegate?.playlistSidebar(self, didSelect: row)
    }
}

/// Accent highlight for the playing item; the usual selection for picked rows.
@MainActor
private final class PlaylistRowBackground: NSTableRowView {
    var isCurrent = false

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isCurrent else { return }
        HUD.accent.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(isCurrent ? 0.12 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

/// One playlist row: position (or a speaker when playing), title, length and where it's from.
@MainActor
private final class PlaylistRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PlaylistRow")
    private let numberLabel = HUD.label(size: 11, weight: .medium, color: HUD.secondaryText, monospaced: true)
    private let playingIcon = NSImageView()
    private let titleLabel = HUD.label(size: 12.5, weight: .medium)
    private let detailLabel = HUD.label(size: 10.5, color: HUD.secondaryText)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        numberLabel.alignment = .right
        playingIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing")
        playingIcon.contentTintColor = HUD.accent
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [numberLabel, playingIcon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            numberLabel.widthAnchor.constraint(equalToConstant: 24),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingIcon.centerXAnchor.constraint(equalTo: numberLabel.centerXAnchor, constant: 4),
            playingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ item: PlaybackItem, number: Int, playing: Bool, duration: TimeInterval?) {
        numberLabel.stringValue = "\(number)"
        numberLabel.isHidden = playing
        playingIcon.isHidden = !playing
        titleLabel.stringValue = item.title
        let source = item.url.isFileURL ? item.url.deletingLastPathComponent().lastPathComponent : (item.url.host ?? "")
        detailLabel.stringValue = [duration.flatMap { $0 > 0 ? TimeFormatter.string($0) : nil }, source.isEmpty ? nil : source]
            .compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel("\(number). \(item.title)\(playing ? ", playing" : ""), \(detailLabel.stringValue)")
    }
}
