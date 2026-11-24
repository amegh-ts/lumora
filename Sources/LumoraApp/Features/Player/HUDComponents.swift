import AppKit

@MainActor
enum HUD {
    static let accent = NSColor.controlAccentColor
    static let primaryText = NSColor.white.withAlphaComponent(0.95)
    static let secondaryText = NSColor.white.withAlphaComponent(0.62)
    static let fadeDuration: TimeInterval = 0.22

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }

    static func panel(cornerRadius: CGFloat) -> HUDPanel {
        HUDPanel(cornerRadius: cornerRadius)
    }

    static func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = primaryText, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font =
            monospaced
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// Floating panel background: Liquid Glass (NSGlassEffectView) on macOS 26 and later, a dark HUD
/// blur before that. Add subviews to `content`, which always sits inside the glass or blur.
@MainActor
final class HUDPanel: NSView {
    let content = NSView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        content.translatesAutoresizingMaskIntoConstraints = false
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(0.35)
            glass.contentView = content
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            blur.layer?.borderWidth = 0.5
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            blur.addSubview(content)
            background = blur
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

final class PassthroughVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
final class HUDButton: NSButton {
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateBackground() }
    }
    private let diameter: CGFloat

    init(symbol: String, size: CGFloat = 15, diameter: CGFloat = 30, tooltip: String) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        image = HUD.symbol(symbol, size: size)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = HUD.primaryText
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(clicked)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func setSymbol(_ name: String, size: CGFloat = 15) {
        image = HUD.symbol(name, size: size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    private func updateBackground() {
        layer?.backgroundColor =
            isHovering && isEnabled
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func clicked() {
        onClick?()
    }
}

@MainActor
final class HUDTextButton: NSButton {
    var onClick: (() -> Void)?

    init(title: String, tooltip: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        contentTintColor = HUD.primaryText
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func setText(_ text: String) {
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: HUD.primaryText
            ]
        )
    }

    @objc private func clicked() {
        onClick?()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

extension NSMenu {
    func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        item.isEnabled = false
        addItem(item)
    }
}

@MainActor
final class OSDView: NSView {
    private let panel = HUD.panel(cornerRadius: 10)
    private let iconView = NSImageView()
    private let label = HUD.label(size: 13, weight: .semibold)
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        alphaValue = 0
        panel.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = HUD.primaryText
        addSubview(panel)
        let stack = NSStackView(views: [iconView, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(stack)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.3) {
        label.stringValue = text
        iconView.image = symbol.flatMap { HUD.symbol($0, size: 14, weight: .semibold) }
        iconView.isHidden = symbol == nil
        hideWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self?.animator().alphaValue = 0
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

@MainActor
final class ThumbnailPreviewView: NSView {
    private let panel = HUD.panel(cornerRadius: 8)
    private let imageView = NSImageView()
    private let timeLabel = HUD.label(size: 12, weight: .semibold, monospaced: true)
    private let chapterLabel = HUD.label(size: 11, color: HUD.secondaryText)
    private var imageHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        timeLabel.alignment = .center
        chapterLabel.alignment = .center
        addSubview(panel)
        panel.content.addSubview(imageView)
        panel.content.addSubview(timeLabel)
        panel.content.addSubview(chapterLabel)
        imageHeight = imageView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 188),
            imageView.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
            imageHeight,
            chapterLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 4),
            chapterLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            chapterLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            timeLabel.topAnchor.constraint(equalTo: chapterLabel.bottomAnchor, constant: 1),
            timeLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            timeLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            timeLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(time: TimeInterval, chapter: String?, aspect: CGFloat) {
        timeLabel.stringValue = TimeFormatter.string(time)
        chapterLabel.stringValue = chapter ?? ""
        chapterLabel.isHidden = (chapter ?? "").isEmpty
        imageHeight.constant = imageView.image == nil ? 0 : 180 / max(aspect, 0.5)
        isHidden = false
    }

    func setImage(_ image: NSImage?, aspect: CGFloat) {
        imageView.image = image
        imageHeight.constant = image == nil ? 0 : 180 / max(aspect, 0.5)
    }

    func hide() {
        isHidden = true
    }
}
