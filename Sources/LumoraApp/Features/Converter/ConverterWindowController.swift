import AppKit

@MainActor
final class ConverterWindowController: NSWindowController {
    static let shared = ConverterWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Convert Media"
        window.center()
        self.init(window: window)
        contentViewController = ConverterViewController(settings: SettingsStore.shared)
    }
}

@MainActor
private final class ConverterViewController: NSViewController {
    private let settings: SettingsStore
    private var source: URL?
    private var destination: URL?
    private var preset = ConverterService.presets[0]

    private let sourceField = NSTextField(labelWithString: "No file selected")
    private let outputField = NSTextField(labelWithString: "Automatic")
    private let statusField = NSTextField(labelWithString: "Choose a source file.")
    private let presetPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24), pullsDown: false)

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 260))
        view = root

        presetPopup.addItems(withTitles: ConverterService.presets.map { $0.title })
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))

        let sourceButton = NSButton(title: "Choose…", target: self, action: #selector(chooseSource(_:)))
        let outputButton = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination(_:)))
        let convertButton = NSButton(title: "Convert", target: self, action: #selector(convert(_:)))
        convertButton.bezelStyle = .rounded
        convertButton.keyEquivalent = "\r"

        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor

        let rows = [
            labeledRow(title: "Source", control: sourceField, button: sourceButton),
            labeledRow(title: "Output", control: outputField, button: outputButton),
            labeledRow(title: "Preset", control: presetPopup, button: NSView()),
            labeledRow(title: "", control: convertButton, button: NSView()),
            statusField
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])
    }

    private func labeledRow(title: String, control: NSView, button: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let stack = NSStackView(views: [label, control, button])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    @objc private func chooseSource(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio, .video, .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.source = url
                self.destination = ConverterService.outputURL(for: url, preset: self.preset)
                self.sourceField.stringValue = url.lastPathComponent
                self.outputField.stringValue = self.destination?.lastPathComponent ?? ""
                self.statusField.stringValue = "Ready to convert."
            }
        }
    }

    @objc private func chooseDestination(_ sender: Any) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = destination?.lastPathComponent ?? "output"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.destination = url
                self?.outputField.stringValue = url.lastPathComponent
            }
        }
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ConverterService.presets.indices.contains(index) else { return }
        preset = ConverterService.presets[index]
        if let source {
            destination = ConverterService.outputURL(for: source, preset: preset)
            outputField.stringValue = destination?.lastPathComponent ?? ""
        }
    }

    @objc private func convert(_ sender: Any) {
        guard let source, let destination else {
            statusField.stringValue = "Choose a source file first."
            return
        }
        statusField.stringValue = "Converting…"
        Task { @MainActor in
            let message = await ConverterService.convert(
                input: source,
                output: destination,
                preset: preset,
                ffmpegPath: settings.ffmpegPath
            )
            if let message {
                statusField.stringValue = "Failed: \(message)"
            } else {
                statusField.stringValue = "Done: \(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }
}
