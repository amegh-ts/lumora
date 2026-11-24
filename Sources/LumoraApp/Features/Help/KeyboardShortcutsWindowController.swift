import AppKit

/// Help › Keyboard Shortcuts (⌘/): every shortcut in labelled groups with key caps,
/// filterable by typing. Single-key shortcuts work while a player window is focused.
@MainActor
final class KeyboardShortcutsWindowController: NSWindowController, NSSearchFieldDelegate {
    static let shared = KeyboardShortcutsWindowController()

    struct Shortcut {
        var keys: [String]
        var action: String
    }

    struct Group {
        var title: String
        var symbol: String
        var shortcuts: [Shortcut]
    }

    static let groups: [Group] = [
        Group(
            title: "Playback", symbol: "play.circle",
            shortcuts: [
                Shortcut(keys: ["Space"], action: "Play / pause (or K)"),
                Shortcut(keys: ["←", "→"], action: "Back / forward 10 s"),
                Shortcut(keys: ["⇧←", "⇧→"], action: "Back / forward 3 s"),
                Shortcut(keys: ["⌥←", "⌥→"], action: "Back / forward 1 min"),
                Shortcut(keys: [",", "."], action: "Previous / next frame"),
                Shortcut(keys: ["[", "]"], action: "Slower / faster"),
                Shortcut(keys: ["="], action: "Normal speed"),
                Shortcut(keys: ["L"], action: "A-B loop"),
                Shortcut(keys: ["B"], action: "Add bookmark"),
                Shortcut(keys: ["⌘J"], action: "Go to time"),
                Shortcut(keys: ["⌘."], action: "Stop")
            ]),
        Group(
            title: "Playlist", symbol: "list.bullet",
            shortcuts: [
                Shortcut(keys: ["⌘←", "⌘→"], action: "Previous / next item"),
                Shortcut(keys: ["N"], action: "Next item"),
                Shortcut(keys: ["P"], action: "Show / hide playlist")
            ]),
        Group(
            title: "Audio", symbol: "speaker.wave.2",
            shortcuts: [
                Shortcut(keys: ["↑", "↓"], action: "Volume up / down"),
                Shortcut(keys: ["M"], action: "Mute"),
                Shortcut(keys: ["A"], action: "Next audio track"),
                Shortcut(keys: ["-", "⇧="], action: "Audio earlier / later")
            ]),
        Group(
            title: "Subtitles", symbol: "captions.bubble",
            shortcuts: [
                Shortcut(keys: ["T"], action: "Next subtitle track"),
                Shortcut(keys: ["Z", "X"], action: "Subtitles earlier / later"),
                Shortcut(keys: ["⌥⌘+", "⌥⌘-"], action: "Bigger / smaller subtitles")
            ]),
        Group(
            title: "Video and Window", symbol: "macwindow",
            shortcuts: [
                Shortcut(keys: ["F"], action: "Full screen (or ⌃⌘F)"),
                Shortcut(keys: ["Esc"], action: "Leave full screen or mini player"),
                Shortcut(keys: ["⌘0", "⌘1", "⌘2"], action: "Half / actual / double size"),
                Shortcut(keys: ["⌘3"], action: "Fit to screen"),
                Shortcut(keys: ["⌥⌘M"], action: "Mini player"),
                Shortcut(keys: ["⌥⌘T"], action: "Keep on top"),
                Shortcut(keys: ["⌥⌘R"], action: "Rotate 90°"),
                Shortcut(keys: ["⇧⌘S"], action: "Screenshot"),
                Shortcut(keys: ["⌘I"], action: "Media info")
            ]),
        Group(
            title: "App", symbol: "app",
            shortcuts: [
                Shortcut(keys: ["⌘O"], action: "Open file or folder"),
                Shortcut(keys: ["⌘U"], action: "Open URL"),
                Shortcut(keys: ["⌘N"], action: "New player window"),
                Shortcut(keys: ["⇧⌘L"], action: "Library"),
                Shortcut(keys: ["⌘,"], action: "Settings"),
                Shortcut(keys: ["⌘/"], action: "Keyboard shortcuts")
            ]),
        Group(
            title: "Mouse and Trackpad", symbol: "computermouse",
            shortcuts: [
                Shortcut(keys: ["Click"], action: "Play / pause"),
                Shortcut(keys: ["Double-click"], action: "Full screen"),
                Shortcut(keys: ["Scroll ↕"], action: "Volume"),
                Shortcut(keys: ["Scroll ↔"], action: "Seek"),
                Shortcut(keys: ["Drag"], action: "Move the window")
            ])
    ]

    private let searchField = NSSearchField()
    private let columns = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No shortcuts match.")

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Keyboard Shortcuts"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("KeyboardShortcuts")
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(searchField)
    }

    private func build() {
        guard let window else { return }
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let note = NSTextField(
            labelWithString:
                "Single keys work while a player window is focused and you're not typing. Every shortcut is also shown next to its command in the menu bar.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = 460

        searchField.placeholderString = "Search shortcuts"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search shortcuts")

        let headerText = NSStackView(views: [heading, note])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        let header = NSStackView(views: [headerText, searchField])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        headerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 28

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        let content = FlippedView()
        let body = NSStackView(views: [columns, emptyLabel])
        body.orientation = .vertical
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(body)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            columns.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        render(filter: "")
    }

    func controlTextDidChange(_ notification: Notification) {
        render(filter: searchField.stringValue)
    }

    /// Two columns, groups split so the columns come out about the same height.
    private func render(filter: String) {
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = Self.groups.compactMap { group -> Group? in
            guard !query.isEmpty else { return group }
            if group.title.lowercased().contains(query) { return group }
            let matches = group.shortcuts.filter {
                $0.action.lowercased().contains(query) || $0.keys.joined(separator: " ").lowercased().contains(query)
            }
            return matches.isEmpty ? nil : Group(title: group.title, symbol: group.symbol, shortcuts: matches)
        }
        emptyLabel.isHidden = !groups.isEmpty
        let total = groups.reduce(0) { $0 + $1.shortcuts.count + 2 }
        var left: [Group] = []
        var right: [Group] = []
        var used = 0
        for group in groups {
            if used < total / 2 || right.isEmpty && left.isEmpty {
                left.append(group)
                used += group.shortcuts.count + 2
            } else {
                right.append(group)
            }
        }
        for column in [left, right] {
            let stack = NSStackView(views: column.map(Self.groupView))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 22
            columns.addArrangedSubview(stack)
        }
    }

    private static func groupView(_ group: Group) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: group.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, title])
        header.spacing = 6

        var rows: [NSView] = []
        for shortcut in group.shortcuts {
            let keys = NSStackView(views: shortcut.keys.map { KeyCap(text: $0) })
            keys.spacing = 4
            let keyColumn = NSView()
            keys.translatesAutoresizingMaskIntoConstraints = false
            keyColumn.addSubview(keys)
            NSLayoutConstraint.activate([
                keyColumn.widthAnchor.constraint(equalToConstant: 124),
                keys.leadingAnchor.constraint(equalTo: keyColumn.leadingAnchor),
                keys.topAnchor.constraint(equalTo: keyColumn.topAnchor),
                keys.bottomAnchor.constraint(equalTo: keyColumn.bottomAnchor)
            ])
            let label = NSTextField(labelWithString: shortcut.action)
            label.font = .systemFont(ofSize: 12.5)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [keyColumn, label])
            row.spacing = 10
            row.alignment = .centerY
            row.setAccessibilityElement(true)
            row.setAccessibilityLabel("\(shortcut.keys.joined(separator: ", ")): \(shortcut.action)")
            rows.append(row)
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6

        let stack = NSStackView(views: [header, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(group.title)
        return stack
    }
}

/// A key drawn like a keyboard key, text centred.
@MainActor
private final class KeyCap: NSView {
    private let text: String
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var textSize: NSSize { (text as NSString).size(withAttributes: [.font: font]) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(24, ceil(textSize.width) + 14), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = textSize
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}

/// Lays out top-down so the scroll view starts at the first group.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
