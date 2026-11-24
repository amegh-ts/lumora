import AppKit
import UniformTypeIdentifiers

/// Tools › Convert Media: re-encodes a file with ffmpeg using a preset.
@MainActor
final class ConverterWindowController: NSWindowController {
    static let shared = ConverterWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Convert Media"
        super.init(window: window)
        contentViewController = ConverterViewController(settings: SettingsStore.shared)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class ConverterViewController: NSViewController {
    private let settings: SettingsStore
    private var source: URL?
    private var destination: URL?
    private var destinationConfirmed = false
    private var isConverting = false
    private var preset = ConverterService.presets[0]

    private let dropZone = FileDropZone()
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presetDetail = NSTextField(labelWithString: "")
    private let outputLabel = NSTextField(labelWithString: "Next to the original")
    private let progress = NSProgressIndicator()
    private let statusField = NSTextField(labelWithString: "")
    private let convertButton = NSButton(title: "Convert", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)

    private static let descriptions: [String: String] = [
        "h264": "Plays everywhere: Macs, iPhones, TVs and browsers. Good quality, medium size.",
        "hevc": "About half the size of H.264 at the same quality. Plays on Apple devices from 2017 on.",
        "av1": "Smallest files, slow to encode. Plays in modern browsers and newer devices.",
        "audio-mp3": "Audio only, for any music player.",
        "audio-aac": "Audio only, smaller than MP3 at the same quality. Best for Apple devices."
    ]

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))

        dropZone.onChoose = { [weak self] in self?.chooseSource() }
        dropZone.onDrop = { [weak self] url in self?.setSource(url) }

        presetPopup.addItems(withTitles: ConverterService.presets.map(\.title))
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetDetail.font = .systemFont(ofSize: 11.5)
        presetDetail.textColor = .secondaryLabelColor
        presetDetail.lineBreakMode = .byWordWrapping
        presetDetail.maximumNumberOfLines = 2
        presetDetail.preferredMaxLayoutWidth = 300
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseDestination(_:)))
        change.bezelStyle = .rounded
        change.controlSize = .small

        let format = Form.section(
            "Output",
            rows: [
                Form.row("Format", detail: nil, control: presetPopup),
                presetDetailRow(),
                Form.row("Save as", control: Form.hStack([outputLabel, change]))
            ])

        progress.style = .bar
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        progress.controlSize = .small
        statusField.font = .systemFont(ofSize: 11.5)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        revealButton.bezelStyle = .rounded
        revealButton.isHidden = true
        convertButton.target = self
        convertButton.action = #selector(convert(_:))
        convertButton.bezelStyle = .rounded
        convertButton.keyEquivalent = "\r"
        convertButton.isEnabled = false
        let footer = NSStackView(views: [statusField, NSView(), revealButton, convertButton])
        footer.spacing = 8

        for view in [dropZone, format, progress, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dropZone.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            dropZone.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            dropZone.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            dropZone.heightAnchor.constraint(equalToConstant: 120),
            format.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            format.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            format.topAnchor.constraint(equalTo: dropZone.bottomAnchor, constant: 18),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            progress.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: format.bottomAnchor, constant: 28),
            root.widthAnchor.constraint(equalToConstant: 560)
        ])
        // Size the window to its content so no row is stretched to fill spare height.
        root.setFrameSize(root.fittingSize)
        view = root
        presetChanged(presetPopup)
    }

    private func presetDetailRow() -> NSView {
        let row = NSView()
        presetDetail.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(presetDetail)
        NSLayoutConstraint.activate([
            presetDetail.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            presetDetail.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            presetDetail.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            presetDetail.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6)
        ])
        return row
    }

    // MARK: Source and output

    private func chooseSource() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio, .video, .audiovisualContent]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.setSource(url) }
        }
    }

    private func setSource(_ url: URL) {
        guard !isConverting else { return }
        source = url
        destination = ConverterService.outputURL(for: url, preset: preset)
        destinationConfirmed = false
        dropZone.show(file: url)
        updateOutputLabel()
        convertButton.isEnabled = true
        revealButton.isHidden = true
        statusField.stringValue = "Ready to convert."
    }

    private func updateOutputLabel() {
        guard let destination else {
            outputLabel.stringValue = "Next to the original"
            return
        }
        let folder = destination.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        outputLabel.stringValue = "\(destination.lastPathComponent) — \(folder)"
        outputLabel.toolTip = destination.path
    }

    @objc private func chooseDestination(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = destination?.lastPathComponent ?? "Converted"
        if let folder = destination?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.destination = url
                // The save panel already asked about replacing an existing file.
                self?.destinationConfirmed = true
                self?.updateOutputLabel()
            }
        }
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ConverterService.presets.indices.contains(index) else { return }
        preset = ConverterService.presets[index]
        presetDetail.stringValue = Self.descriptions[preset.id] ?? ""
        if let source {
            destination = ConverterService.outputURL(for: source, preset: preset)
            destinationConfirmed = false
            updateOutputLabel()
        }
    }

    // MARK: Convert

    @objc private func convert(_ sender: Any?) {
        if isConverting {
            ConverterService.cancelActive()
            return
        }
        guard let source, let destination else { return }
        let ffmpeg = settings.ffmpegPath
        if !ffmpeg.isEmpty, !FileManager.default.isExecutableFile(atPath: ffmpeg) {
            statusField.stringValue = "ffmpeg wasn't found. Install it with Homebrew (brew install ffmpeg) or set its location in Settings › Tools."
            return
        }
        setConverting(true)
        statusField.stringValue = "Converting \(source.lastPathComponent)…"
        Task { @MainActor in
            let message = await ConverterService.convert(
                input: source, output: destination, preset: preset, ffmpegPath: ffmpeg, overwrite: destinationConfirmed)
            setConverting(false)
            if let message {
                statusField.stringValue = message.contains("cancel") ? "Cancelled." : "Couldn't convert: \(message)"
            } else {
                statusField.stringValue = "Saved \(destination.lastPathComponent)."
                revealButton.isHidden = false
            }
        }
    }

    private func setConverting(_ converting: Bool) {
        isConverting = converting
        convertButton.title = converting ? "Cancel" : "Convert"
        convertButton.keyEquivalent = converting ? "\u{1b}" : "\r"
        presetPopup.isEnabled = !converting
        dropZone.isEnabled = !converting
        revealButton.isHidden = true
        if converting {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    @objc private func reveal(_ sender: Any?) {
        guard let destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }
}

/// Dashed area that accepts a dropped media file, or opens a file picker when clicked.
@MainActor
private final class FileDropZone: NSView {
    var onChoose: (() -> Void)?
    var onDrop: ((URL) -> Void)?
    var isEnabled = true

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Drop a video or audio file here")
    private let detail = NSTextField(labelWithString: "or click to choose one")
    private var isTargeted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        icon.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Choose a file to convert")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(file url: URL) {
        title.stringValue = url.lastPathComponent
        var parts = [url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")]
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        detail.stringValue = parts.joined(separator: " · ") + " — click to choose another"
        icon.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        setAccessibilityLabel("Source: \(url.lastPathComponent). Choose another file")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        (isTargeted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        if isTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onChoose?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onChoose?()
        return true
    }

    private func mediaURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let url = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)?.first as? URL,
            let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent)
        else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, mediaURL(from: sender) != nil else { return [] }
        isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard isEnabled, let url = mediaURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}
