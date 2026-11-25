import AppKit

/// A chooser for long lists (countries, categories, fonts): type to jump to a match, and the
/// list opens at a fixed height instead of filling the screen like a long pop-up menu.
@MainActor
final class SearchableChoice: NSComboBox, NSComboBoxDelegate {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var options: [String] = []

    init(visibleItems: Int = 12) {
        super.init(frame: .zero)
        numberOfVisibleItems = visibleItems
        completes = true
        hasVerticalScroller = true
        usesDataSource = false
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOptions(_ titles: [String], selected: Int) {
        options = titles
        removeAllItems()
        addItems(withObjectValues: titles)
        select(index: titles.indices.contains(selected) ? selected : 0, notify: false)
    }

    func select(index: Int, notify: Bool = true) {
        guard options.indices.contains(index) else { return }
        selectedIndex = index
        selectItem(at: index)
        stringValue = options[index]
        if notify {
            onSelect?(index)
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        let index = indexOfSelectedItem
        guard options.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    /// Typed text picks the first option starting with it (or containing it); anything else
    /// puts the current choice back.
    func controlTextDidEndEditing(_ notification: Notification) {
        let text = stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let match =
            options.firstIndex { $0.lowercased() == text }
            ?? options.firstIndex { $0.lowercased().hasPrefix(text) }
            ?? (text.isEmpty ? nil : options.firstIndex { $0.lowercased().contains(text) })
        if let match {
            if match != selectedIndex {
                select(index: match)
            } else {
                stringValue = options[match]
            }
        } else {
            stringValue = options.indices.contains(selectedIndex) ? options[selectedIndex] : ""
        }
    }
}
