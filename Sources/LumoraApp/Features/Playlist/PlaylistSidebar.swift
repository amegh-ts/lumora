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

    init(store: PlaylistStore) {
        self.store = store
        addButton = PlaylistSidebar.makeButton(symbol: "plus", tooltip: "Add media")
        removeButton = PlaylistSidebar.makeButton(symbol: "minus", tooltip: "Remove selected")
        clearButton = PlaylistSidebar.makeButton(symbol: "trash", tooltip: "Clear playlist")
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
        tableView.rowHeight = 34
        tableView.style = .inset
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
        for button in [addButton, removeButton, clearButton] {
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.target = self
            button.action = #selector(buttonTapped(_:))
        }

        let header = NSStackView(views: [titleLabel, addButton, removeButton, clearButton])
        header.orientation = .horizontal
        header.spacing = 4

        let stack = NSStackView(views: [header, scrollView])
        stack.orientation = .vertical
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

    /// The playing item is marked by its icon, not the table selection, so "Remove selected"
    /// only ever removes what the user picked.
    func reload() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection.filteredIndexSet { $0 < store.items.count }, byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("item")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let imageView = NSImageView(frame: .zero)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.imageView = imageView
            cell.textField = textField
        }
        let item = store.items[row]
        cell.textField?.stringValue = item.title
        cell.imageView?.image = NSImage(
            systemSymbolName: row == store.currentIndex ? "play.circle.fill" : "film",
            accessibilityDescription: nil
        )
        return cell
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
