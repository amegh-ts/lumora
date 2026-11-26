import AppKit

/// A short notice above the control bar with up to two actions, e.g. "Resumed at 42:10 · Start
/// over", "Screenshot saved · Show in Finder", or "Up next: Episode 2 in 5 · Play Now · Cancel".
@MainActor
final class PlayerToast: NSView {
    struct Action {
        var title: String
        var primary = false
        var handler: () -> Void
    }

    private let panel = HUD.panel(cornerRadius: 12)
    private let icon = NSImageView()
    private let titleLabel = HUD.label(size: 13, weight: .semibold)
    private let detailLabel = HUD.label(size: 11.5, color: HUD.secondaryText)
    private let buttons = NSStackView()
    private var hideWork: DispatchWorkItem?
    private var countdownWork: DispatchWorkItem?
    private var actions: [Action] = []
    private(set) var isShowing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .vibrantDark)
        isHidden = true
        alphaValue = 0
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.contentTintColor = HUD.accent
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        buttons.spacing = 6
        let row = NSStackView(views: [icon, text, buttons])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(row)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: panel.content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: panel.content.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: panel.content.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: panel.content.bottomAnchor, constant: -9),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows the notice for `duration` seconds (0 keeps it until dismissed).
    func show(_ title: String, detail: String? = nil, symbol: String, actions: [Action], duration: TimeInterval = 5) {
        countdownWork?.cancel()
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.actions = actions
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(tapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            if action.primary {
                button.keyEquivalent = "\r"
                button.bezelColor = HUD.accent
            }
            buttons.addArrangedSubview(button)
        }
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: accessibilityLabel() ?? title])
        isShowing = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = 1
        }
        hideWork?.cancel()
        guard duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// "Up next" style: counts down `seconds`, updating the title, then runs `finish`.
    func countdown(
        seconds: Int, title: @escaping (Int) -> String, detail: String?, symbol: String, actions: [Action], finish: @escaping () -> Void
    ) {
        show(title(seconds), detail: detail, symbol: symbol, actions: actions, duration: 0)
        tick(seconds, title: title, finish: finish)
    }

    private func tick(_ remaining: Int, title: @escaping (Int) -> String, finish: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isShowing else { return }
            if remaining <= 1 {
                self.dismiss()
                finish()
            } else {
                self.titleLabel.stringValue = title(remaining - 1)
                self.tick(remaining - 1, title: title, finish: finish)
            }
        }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func dismiss() {
        hideWork?.cancel()
        countdownWork?.cancel()
        guard isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShowing else { return }
                self.isHidden = true
            }
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        dismiss()
        action.handler()
    }
}

/// Brief "« 10" / "10 »" ripple on the side of the video after a skip; repeated skips add up.
@MainActor
final class SkipRipple: NSView {
    private let left = SkipBubble(forward: false)
    private let right = SkipBubble(forward: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for bubble in [left, right] {
            addSubview(bubble)
        }
        NSLayoutConstraint.activate([
            left.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.centerXAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            right.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(seconds: TimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        (seconds < 0 ? left : right).bump(by: abs(seconds))
    }
}

@MainActor
private final class SkipBubble: NSView {
    private let label = HUD.label(size: 15, weight: .bold)
    private let forward: Bool
    private var total: TimeInterval = 0
    private var hideWork: DispatchWorkItem?

    init(forward: Bool) {
        self.forward = forward
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.cornerRadius = 90
        alphaValue = 0
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 180),
            heightAnchor.constraint(equalToConstant: 180),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            forward
                ? label.trailingAnchor.constraint(equalTo: centerXAnchor, constant: -22)
                : label.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func bump(by seconds: TimeInterval) {
        total = alphaValue > 0.05 ? total + seconds : seconds
        let amount = total >= 60 && total.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(total / 60)) min" : "\(Int(total)) s"
        label.stringValue = forward ? "\(amount) »" : "« \(amount)"
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
