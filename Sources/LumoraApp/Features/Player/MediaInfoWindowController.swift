import AppKit

/// Window › Media Info: technical details of what the front player is playing, refreshed
/// every second while open (bitrates and dropped frames change during playback).
@MainActor
final class MediaInfoWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MediaInfoWindowController()

    private weak var player: PlayerViewController?
    private let textView = NSTextView()
    private var timer: Timer?

    private static let properties = [
        "filename", "file-format", "duration", "file-size", "demuxer-via-network",
        "video-codec", "video-params/w", "video-params/h", "video-params/pixelformat", "video-params/hw-pixelformat", "video-params/gamma",
        "video-params/primaries", "container-fps", "estimated-vf-fps", "video-bitrate", "hwdec-current",
        "current-vo", "frame-drop-count", "decoder-frame-drop-count",
        "audio-codec-name", "audio-params/samplerate", "audio-params/hr-channels", "audio-bitrate", "current-ao",
        "current-tracks/sub/title", "current-tracks/sub/lang", "current-tracks/sub/codec",
        "demuxer-cache-duration", "cache-speed"
    ]

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        window.title = "Media Info"
        window.isFloatingPanel = true
        window.hidesOnDeactivate = true
        window.minSize = NSSize(width: 340, height: 260)
        window.setFrameAutosaveName("MediaInfo")
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.setAccessibilityLabel("Media information")
        scroll.documentView = textView
        window.contentView = scroll
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(for player: PlayerViewController) {
        self.player = player
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MediaInfoWindowController.shared.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let player, player.engine.isActive, player.engine.hasMedia else {
            render(nil)
            return
        }
        let title = player.engine.currentItem?.title
        let location = player.engine.currentItem.map { $0.url.isFileURL ? $0.url.path : $0.url.absoluteString }
        player.engine.readProperties(Self.properties) { [weak self] values in
            self?.render(values, title: title, location: location)
        }
    }

    private func render(_ values: [String: String]?, title: String? = nil, location: String? = nil) {
        let text = NSMutableAttributedString()
        guard let values else {
            text.append(
                NSAttributedString(
                    string: "Nothing is playing.", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            textView.textStorage?.setAttributedString(text)
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 130)]
        paragraph.headIndent = 130
        paragraph.paragraphSpacing = 3
        let labelFont = NSFont.systemFont(ofSize: 12)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        func section(_ name: String, _ rows: [(String, String?)]) {
            let present = rows.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
            guard !present.isEmpty else { return }
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n"))
            }
            text.append(
                NSAttributedString(
                    string: name.uppercased() + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            for (label, value) in present {
                text.append(
                    NSAttributedString(
                        string: label + "\t", attributes: [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]))
                text.append(
                    NSAttributedString(string: value + "\n", attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
            }
        }

        let isStream = values["demuxer-via-network"] == "yes"
        section(
            "General",
            [
                ("Title", title),
                (isStream ? "URL" : "File", location),
                ("Container", values["file-format"].map(Self.container)),
                ("Duration", values["duration"].flatMap(Double.init).map { TimeFormatter.string($0) }),
                ("Size", values["file-size"].flatMap(Int64.init).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
            ])
        let width = values["video-params/w"]
        let height = values["video-params/h"]
        section(
            "Video",
            [
                ("Codec", values["video-codec"].map(Self.shortCodec)),
                ("Resolution", width.flatMap { w in height.map { "\(w) × \($0)" } }),
                ("Frame rate", Self.fps(values["estimated-vf-fps"] ?? values["container-fps"])),
                ("Bitrate", Self.bitrate(values["video-bitrate"])),
                ("Dynamic range", values["video-params/gamma"].map(Self.dynamicRange)),
                ("Colour", values["video-params/primaries"]),
                ("Pixel format", values["video-params/hw-pixelformat"] ?? values["video-params/pixelformat"]),
                ("Hardware decoding", values["hwdec-current"].map { $0 == "no" || $0.isEmpty ? "Off (software)" : "On (\($0))" }),
                ("Renderer", values["current-vo"]),
                ("Dropped frames", Self.drops(values["frame-drop-count"], values["decoder-frame-drop-count"]))
            ])
        section(
            "Audio",
            [
                ("Codec", values["audio-codec-name"]),
                ("Channels", values["audio-params/hr-channels"]),
                ("Sample rate", values["audio-params/samplerate"].flatMap(Double.init).map { String(format: "%g kHz", $0 / 1000) }),
                ("Bitrate", Self.bitrate(values["audio-bitrate"])),
                ("Output", values["current-ao"])
            ])
        section(
            "Subtitles",
            [
                ("Track", values["current-tracks/sub/title"] ?? values["current-tracks/sub/lang"]),
                ("Format", values["current-tracks/sub/codec"])
            ])
        if isStream {
            section(
                "Network",
                [
                    ("Buffered ahead", values["demuxer-cache-duration"].flatMap(Double.init).map { String(format: "%.0f s", $0) }),
                    (
                        "Download speed",
                        values["cache-speed"].flatMap(Double.init).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" }
                    )
                ])
        }
        // Keep the user's selection when the numbers refresh.
        let selection = textView.selectedRanges
        textView.textStorage?.setAttributedString(text)
        if selection.allSatisfy({ $0.rangeValue.upperBound <= text.length }) {
            textView.selectedRanges = selection
        }
    }

    /// "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10" → "H.264".
    private static func shortCodec(_ name: String) -> String {
        name.components(separatedBy: " / ").first ?? name
    }

    /// FFmpeg names a demuxer by every extension it covers ("mov,mp4,m4a,…"); show the common one.
    private static func container(_ name: String) -> String {
        let names = name.split(separator: ",").map(String.init)
        if names.contains("mp4") { return "MP4 / MOV" }
        if names.contains("matroska") || names.contains("webm") { return "Matroska / WebM" }
        return (names.first ?? name).uppercased()
    }

    private static func fps(_ value: String?) -> String? {
        guard let number = value.flatMap(Double.init), number > 0 else { return nil }
        return String(format: "%.3g fps", number)
    }

    private static func bitrate(_ value: String?) -> String? {
        guard let bits = value.flatMap(Double.init), bits > 0 else { return nil }
        return bits >= 1_000_000 ? String(format: "%.1f Mbps", bits / 1_000_000) : String(format: "%.0f kbps", bits / 1000)
    }

    private static func dynamicRange(_ gamma: String) -> String {
        switch gamma {
        case "pq": return "HDR10 (PQ)"
        case "hlg": return "HLG"
        default: return "SDR (\(gamma))"
        }
    }

    private static func drops(_ output: String?, _ decoder: String?) -> String? {
        guard output != nil || decoder != nil else { return nil }
        return "\(output ?? "0") output · \(decoder ?? "0") decoder"
    }
}
