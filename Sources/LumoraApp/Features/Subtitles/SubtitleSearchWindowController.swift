import AppKit

@MainActor
final class SubtitleSearchWindowController: NSWindowController {
    static let shared = SubtitleSearchWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Search Subtitles"
        window.center()
        self.init(window: window)
        contentViewController = SubtitleSearchViewController(settings: SettingsStore.shared)
    }
}

@MainActor
private final class SubtitleSearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let settings: SettingsStore
    private let queryField = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
    private let statusField = NSTextField(labelWithString: "Enter a title to search OpenSubtitles.")
    private let tableView = NSTableView()
    private var results: [SubtitleSearchResult] = []

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        view = root

        queryField.placeholderString = "Movie title"
        let searchButton = NSButton(title: "Search", target: self, action: #selector(search(_:)))
        searchButton.bezelStyle = .rounded

        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Subtitle"
        titleColumn.width = 300
        let languageColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        languageColumn.title = "Language"
        languageColumn.width = 90
        let releaseColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("release"))
        releaseColumn.title = "Release"
        releaseColumn.width = 150
        tableView.addTableColumn(titleColumn)
        tableView.addTableColumn(languageColumn)
        tableView.addTableColumn(releaseColumn)
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        let searchRow = NSStackView(views: [queryField, searchButton])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8

        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [searchRow, scrollView, statusField])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("title")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        let result = results[row]
        switch identifier.rawValue {
        case "language": cell.textField?.stringValue = result.language
        case "release": cell.textField?.stringValue = result.releaseName
        default: cell.textField?.stringValue = result.title
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        nil
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = textField
        return cell
    }

    @objc private func search(_ sender: Any) {
        guard !settings.openSubtitlesAPIKey.isEmpty else {
            statusField.stringValue = "Add an OpenSubtitles API key in Settings."
            return
        }
        statusField.stringValue = "Searching…"
        Task { @MainActor in
            let found = await OpenSubtitlesService.search(
                query: queryField.stringValue,
                languages: settings.subtitleLanguages,
                apiKey: settings.openSubtitlesAPIKey
            )
            results = found
            tableView.reloadData()
            statusField.stringValue = found.isEmpty ? "No results." : "\(found.count) result(s). Double-click to download."
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    @objc private func downloadSelected(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < results.count else { return }
        let result = results[row]
        statusField.stringValue = "Downloading…"
        Task { @MainActor in
            guard let data = await OpenSubtitlesService.download(result: result, apiKey: settings.openSubtitlesAPIKey) else {
                statusField.stringValue = "Download failed."
                return
            }
            guard let track = SubtitleService.saveDownloaded(
                data,
                language: result.language,
                filename: result.title
            ) else {
                statusField.stringValue = "Could not save subtitle."
                return
            }
            NotificationCenter.default.post(name: .lumoraDidDownloadSubtitle, object: track)
            statusField.stringValue = "Saved \(track.title)."
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.target = self
        tableView.doubleAction = #selector(downloadSelected(_:))
    }
}
