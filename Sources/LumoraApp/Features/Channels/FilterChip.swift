import AppKit

/// A pill-shaped filter button for the dark player panels ("All countries ▾"). Clicking opens a
/// popover with a search field and a list about 12 rows tall; the first option clears the filter.
@MainActor
final class FilterChip: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private var options: [String] = []
    private var icons: [String?] = []
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var hovering = false {
        didSet { updateLook() }
    }
    private var tracking: NSTrackingArea?

    private var popover: NSPopover?
    private let search = NSSearchField()
    private let list = NSTableView()
    private var filtered: [Int] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 13
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        let row = NSStackView(views: [label, chevron])
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        updateLook()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// `icons` are optional emoji shown before each option (flags for countries).
    func setOptions(_ titles: [String], icons: [String?] = [], selected: Int) {
        options = titles
        self.icons = icons.count == titles.count ? icons : Array(repeating: nil, count: titles.count)
        select(index: titles.indices.contains(selected) ? selected : 0, notify: false)
    }

    func select(index: Int, notify: Bool = true) {
        guard options.indices.contains(index) else { return }
        selectedIndex = index
        let icon = icons.indices.contains(index) ? icons[index] : nil
        // The chip shows the name only; counts belong in the list.
        let title = options[index].replacingOccurrences(of: #"\s*\([\d,.\s]+\)$"#, with: "", options: .regularExpression)
        label.stringValue = [icon, title].compactMap { $0 }.joined(separator: " ")
        setAccessibilityValue(options[index])
        updateLook()
        if notify {
            onSelect?(index)
        }
    }

    private func updateLook() {
        let active = selectedIndex > 0
        let base = active ? HUD.accent.withAlphaComponent(hovering ? 0.45 : 0.32) : NSColor.white.withAlphaComponent(hovering ? 0.14 : 0.08)
        layer?.backgroundColor = base.cgColor
        label.textColor = active ? .white : HUD.primaryText
        chevron.contentTintColor = active ? .white : HUD.secondaryText
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
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        showList()
    }

    override func accessibilityPerformPress() -> Bool {
        showList()
        return true
    }

    // MARK: Popover

    func showList() {
        guard !options.isEmpty else { return }
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 360))
        search.placeholderString = "Search"
        search.stringValue = ""
        search.delegate = self
        search.sendsSearchStringImmediately = true
        if list.tableColumns.isEmpty {
            list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("option")))
            list.headerView = nil
            list.rowHeight = 26
            list.style = .plain
            list.backgroundColor = .clear
            list.dataSource = self
            list.delegate = self
            list.target = self
            list.action = #selector(pick(_:))
        }
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for view in [search, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let rows = CGFloat(min(options.count, 12))
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 260),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.heightAnchor.constraint(equalToConstant: rows * 26 + 4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        search.isHidden = options.count <= 12
        if search.isHidden {
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 6).isActive = true
        }
        controller.view = root
        filterList("")
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.appearance = NSAppearance(named: .darkAqua)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        if !search.isHidden {
            popover.contentViewController?.view.window?.makeFirstResponder(search)
        }
        if let row = filtered.firstIndex(of: selectedIndex) {
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
        }
    }

    private func filterList(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = options.indices.filter { query.isEmpty || $0 == 0 || options[$0].lowercased().contains(query) }
        list.reloadData()
        if !query.isEmpty, filtered.count > 1 {
            list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        filterList(search.stringValue)
    }

    /// Return in the search field picks the highlighted option; arrows move it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            choose(row: list.selectedRow)
            return true
        case #selector(NSResponder.moveDown(_:)):
            let row = min(list.selectedRow + 1, filtered.count - 1)
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.moveUp(_:)):
            let row = max(list.selectedRow - 1, 0)
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            popover?.close()
            return true
        default:
            return false
        }
    }

    @objc private func pick(_ sender: NSTableView) {
        choose(row: sender.clickedRow)
    }

    private func choose(row: Int) {
        guard filtered.indices.contains(row) else { return }
        popover?.close()
        select(index: filtered[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let index = filtered[row]
        let icon = icons.indices.contains(index) ? icons[index] : nil
        let label = NSTextField(labelWithString: [icon, options[index]].compactMap { $0 }.joined(separator: "  "))
        label.font = .systemFont(ofSize: 12.5, weight: index == selectedIndex ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
