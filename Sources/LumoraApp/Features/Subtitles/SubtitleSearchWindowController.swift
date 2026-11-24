import AppKit

/// Subtitles › Search Online: finds subtitles on OpenSubtitles and adds the chosen one to the
/// video that's playing.
@MainActor
final class SubtitleSearchWindowController: NSWindowController {
    static let shared = SubtitleSearchWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Search Subtitles"
        window.minSize = NSSize(width: 520, height: 320)
        super.init(window: window)
        contentViewController = SubtitleSearchViewController(settings: SettingsStore.shared)
        window.setContentSize(NSSize(width: 680, height: 480))
        window.setFrameAutosaveName("SubtitleSearch")
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens with the current video's name already in the search field.
    override func showWindow(_ sender: Any?) {
        let player =
            (NSApp.mainWindow?.contentViewController as? PlayerViewController)
            ?? NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.first
        if let search = contentViewController as? SubtitleSearchViewController {
            search.prefill(player?.engine.currentItem.map { $0.url.isFileURL ? $0.url.deletingPathExtension().lastPathComponent : $0.title })
        }
        super.showWindow(sender)
    }
}

@MainActor
final class SubtitleSearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: SettingsStore
    private let queryField = NSSearchField()
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tableView = NSTableView()
    private let spinner = NSProgressIndicator()
    private let statusField = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Add to Video", target: nil, action: nil)
    private let placeholder = NSStackView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderButton = NSButton(title: "Open Subtitle Settings", target: nil, action: nil)
    private var results: [SubtitleSearchResult] = []
    private var languages: [(title: String, codes: String)] = []

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prefill(_ query: String?) {
        _ = view
        if let query, queryField.stringValue.isEmpty || !results.isEmpty {
            queryField.stringValue = query
        }
        rebuildLanguages()
        updatePlaceholder()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 480))

        queryField.placeholderString = "Movie or episode title"
        queryField.target = self
        queryField.action = #selector(search(_:))
        queryField.sendsWholeSearchString = true
        queryField.setAccessibilityLabel("Search for")
        languagePopup.target = self
        languagePopup.action = #selector(search(_:))
        languagePopup.setAccessibilityLabel("Language")
        let searchButton = NSButton(title: "Search", target: self, action: #selector(search(_:)))
        searchButton.bezelStyle = .rounded
        searchButton.keyEquivalent = "\r"
        let header = NSStackView(views: [queryField, languagePopup, searchButton])
        header.spacing = 8
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let columns: [(String, String, CGFloat)] = [("name", "Subtitle", 360), ("language", "Language", 110), ("downloads", "Downloads", 90)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.style = .inset
        tableView.rowHeight = 40
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(download(_:))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.setAccessibilityLabel("Subtitles found")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.preferredMaxLayoutWidth = 380
        placeholderButton.target = self
        placeholderButton.action = #selector(openSettings(_:))
        placeholderButton.bezelStyle = .rounded
        let placeholderIcon = NSImageView(image: NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil) ?? NSImage())
        placeholderIcon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        for view in [placeholderIcon, placeholderLabel, placeholderButton] as [NSView] {
            placeholder.addArrangedSubview(view)
        }
        placeholder.orientation = .vertical
        placeholder.spacing = 10

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusField.font = .systemFont(ofSize: 11.5)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadButton.target = self
        downloadButton.action = #selector(download(_:))
        downloadButton.bezelStyle = .rounded
        downloadButton.isEnabled = false
        let footer = NSStackView(views: [spinner, statusField, NSView(), downloadButton])
        footer.spacing = 8

        for view in [header, scroll, placeholder, footer] as [NSView] {
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
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
        rebuildLanguages()
        updatePlaceholder()
    }

    /// The languages from Settings first, then common ones.
    private func rebuildLanguages() {
        let preferred = PlaybackEngine.languageList(settings.subtitleLanguages)
        var options: [(String, String)] = []
        if !preferred.isEmpty {
            let names = preferred.split(separator: ",").map { Locale.current.localizedString(forLanguageCode: String($0)) ?? String($0) }
            options.append(("My Languages (\(names.joined(separator: ", ")))", preferred))
        }
        for code in ["en", "es", "fr", "de", "it", "pt", "ru", "ar", "hi", "ml", "ta", "ja", "ko", "zh"] where code != preferred {
            options.append((Locale.current.localizedString(forLanguageCode: code) ?? code, code))
        }
        let selected = languagePopup.indexOfSelectedItem
        languages = options
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: options.map(\.0))
        languagePopup.selectItem(at: selected >= 0 && selected < options.count ? selected : 0)
    }

    private func updatePlaceholder(message: String? = nil) {
        let missingKey = settings.openSubtitlesAPIKey.isEmpty
        placeholderButton.isHidden = !missingKey
        if missingKey {
            placeholderLabel.stringValue = "Searching needs a free OpenSubtitles API key. Add it in Settings › Subtitles."
        } else {
            placeholderLabel.stringValue = message ?? "Search by movie or episode title. The video that's playing is filled in for you."
        }
        placeholder.isHidden = !results.isEmpty
    }

    @objc private func openSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSubtitleSettings(nil)
    }

    // MARK: Search and download

    @objc private func search(_ sender: Any?) {
        let query = queryField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !settings.openSubtitlesAPIKey.isEmpty else {
            updatePlaceholder()
            return
        }
        guard !query.isEmpty else {
            statusField.stringValue = "Type a title to search."
            return
        }
        let codes = languages.indices.contains(languagePopup.indexOfSelectedItem) ? languages[languagePopup.indexOfSelectedItem].codes : "en"
        spinner.startAnimation(nil)
        statusField.stringValue = "Searching OpenSubtitles…"
        Task { @MainActor in
            let outcome = await OpenSubtitlesService.searchResults(query: query, languages: codes, apiKey: settings.openSubtitlesAPIKey)
            spinner.stopAnimation(nil)
            switch outcome {
            case .success(let found):
                results = found.sorted { $0.downloads > $1.downloads }
                statusField.stringValue = found.isEmpty ? "" : "\(found.count) found. Double-click one to add it to the video."
                tableView.reloadData()
                updatePlaceholder(message: found.isEmpty ? "No subtitles found for “\(query)”. Try a shorter title or another language." : nil)
            case .failure(let error):
                results = []
                tableView.reloadData()
                statusField.stringValue = ""
                updatePlaceholder(message: error.message)
            }
            downloadButton.isEnabled = false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        downloadButton.isEnabled = tableView.selectedRow >= 0
    }

    @objc private func download(_ sender: Any?) {
        let row = sender as? NSTableView === tableView && tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard results.indices.contains(row) else { return }
        let result = results[row]
        spinner.startAnimation(nil)
        downloadButton.isEnabled = false
        statusField.stringValue = "Downloading \(result.title)…"
        Task { @MainActor in
            defer {
                spinner.stopAnimation(nil)
                downloadButton.isEnabled = tableView.selectedRow >= 0
            }
            guard let data = await OpenSubtitlesService.download(result: result, apiKey: settings.openSubtitlesAPIKey) else {
                statusField.stringValue = "Download failed. OpenSubtitles may have reached its daily limit for this key."
                return
            }
            guard let track = SubtitleService.saveDownloaded(data, language: result.language, filename: result.title) else {
                statusField.stringValue = "The subtitle couldn't be saved."
                return
            }
            NotificationCenter.default.post(name: .lumoraDidDownloadSubtitle, object: track)
            statusField.stringValue = "Added “\(track.title)” to the video."
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let result = results[row]
        let cell = NSTableCellView()
        let text: String
        switch id {
        case "language":
            text = Locale.current.localizedString(forLanguageCode: result.language) ?? result.language
        case "downloads":
            text = result.downloads.formatted(.number.notation(.compactName))
        default:
            text = result.title
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = id == "name" ? .systemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 12.5)
        label.textColor = id == "name" ? .labelColor : .secondaryLabelColor
        var views: [NSView] = [label]
        if id == "name", !result.releaseName.isEmpty, result.releaseName != result.title {
            let release = NSTextField(labelWithString: result.releaseName)
            release.font = .systemFont(ofSize: 11)
            release.textColor = .secondaryLabelColor
            release.lineBreakMode = .byTruncatingMiddle
            views.append(release)
        }
        if id == "name", result.hearingImpaired {
            label.stringValue += "  ·  SDH"
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        for view in views {
            (view as? NSTextField)?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return cell
    }
}
