import AppKit
import Combine

@MainActor
final class LibraryWindowController: NSWindowController {
    static let shared = LibraryWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Library"
        window.center()
        self.init(window: window)
        contentViewController = LibraryViewController(library: LibraryStore.shared)
    }
}

@MainActor
private final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let library: LibraryStore
    private let tableView = NSTableView()
    private var records: [LibraryRecord] = []
    private var cancellable: AnyCancellable?

    init(library: LibraryStore) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        view = scrollView
        configureTable()
        cancellable = library.$records.sink { [weak self] _ in
            self?.reload()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func configureTable() {
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        title.title = "Title"
        title.width = 340
        let progress = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("progress"))
        progress.title = "Progress"
        progress.width = 160
        let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        date.title = "Last Played"
        date.width = 180
        tableView.addTableColumn(title)
        tableView.addTableColumn(progress)
        tableView.addTableColumn(date)
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected(_:))
    }

    private func reload() {
        records = library.recent()
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("title")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        let record = records[row]
        switch identifier.rawValue {
        case "progress":
            cell.textField?.stringValue = record.watched
                ? "Watched"
                : "\(TimeFormatter.string(record.resumeTime)) / \(TimeFormatter.string(record.duration))"
        case "date":
            cell.textField?.stringValue = record.lastPlayed.formatted(date: .abbreviated, time: .shortened)
        default:
            cell.textField?.stringValue = record.title
            cell.imageView?.image = NSImage(
                systemSymbolName: record.watched ? "checkmark.circle.fill" : "play.circle",
                accessibilityDescription: nil
            )
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let imageView = NSImageView(frame: NSRect(x: 4, y: 4, width: 18, height: 18))
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.imageView = imageView
        cell.textField = textField
        return cell
    }

    @objc private func openSelected(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < records.count else { return }
        guard let controller = NSApplication.shared.windows
            .compactMap({ $0.windowController as? MainWindowController })
            .first else { return }
        controller.open([records[row].url])
    }
}
