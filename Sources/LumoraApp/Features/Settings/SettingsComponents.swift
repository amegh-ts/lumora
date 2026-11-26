import AppKit

/// Building blocks for the Settings panes, styled like macOS System Settings: grouped rounded
/// sections, label on the left, control on the right, controls bound to closures.
@MainActor
enum Form {
    static let rowHeight: CGFloat = 36
    static let labelWidth: CGFloat = 200

    /// A titled group of rows with an optional footnote.
    static func section(_ title: String?, footnote: String? = nil, rows: [NSView]) -> NSView {
        let box = SectionBox()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                stack.addArrangedSubview(separator())
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2)
        ])

        var views: [NSView] = []
        if let title {
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            header.textColor = .labelColor
            views.append(header)
        }
        views.append(box)
        if let footnote {
            let note = NSTextField(wrappingLabelWithString: footnote)
            note.font = .systemFont(ofSize: 11)
            note.preferredMaxLayoutWidth = SettingsPaneController.width - 48
            note.textColor = .secondaryLabelColor
            views.append(note)
        }
        let outer = NSStackView(views: views)
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        for view in views {
            view.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
        return outer
    }

    static func row(_ title: String, detail: String? = nil, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [label])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.preferredMaxLayoutWidth = 300
            detailLabel.maximumNumberOfLines = 2
            texts.addArrangedSubview(detailLabel)
        }
        texts.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(texts)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight),
            texts.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            texts.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 7),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 5),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -5)
        ])
        row.setContentHuggingPriority(.required, for: .vertical)
        texts.setHuggingPriority(.required, for: .vertical)
        return row
    }

    static func toggle(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSSwitch {
        let control = BoundSwitch()
        control.controlSize = .small
        control.state = get() ? .on : .off
        control.onChange = { set($0.state == .on) }
        control.refresh = { [weak control] in control?.state = get() ? .on : .off }
        return control
    }

    static func popup<Value: Equatable>(
        _ options: [(String, Value)],
        _ get: @escaping () -> Value,
        _ set: @escaping (Value) -> Void
    ) -> NSPopUpButton {
        let control = BoundPopUp(frame: .zero, pullsDown: false)
        control.controlSize = .regular
        control.addItems(withTitles: options.map(\.0))
        let select: () -> Void = { [weak control] in
            guard let control else { return }
            control.selectItem(at: options.firstIndex { $0.1 == get() } ?? 0)
        }
        select()
        control.onChange = { popup in
            let index = popup.indexOfSelectedItem
            if options.indices.contains(index) {
                set(options[index].1)
            }
        }
        control.refresh = select
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return control
    }

    /// Slider with a live value label; `format` turns the value into text.
    static func slider(
        range: ClosedRange<Double>,
        step: Double? = nil,
        width: CGFloat = 200,
        format: @escaping (Double) -> String,
        _ get: @escaping () -> Double,
        _ set: @escaping (Double) -> Void
    ) -> NSView {
        let slider = BoundSlider(value: get(), minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        let label = NSTextField(labelWithString: format(get()))
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        if let step, step > 0 {
            slider.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
            slider.allowsTickMarkValuesOnly = true
            slider.tickMarkPosition = .below
            if slider.numberOfTickMarks > 25 {
                slider.numberOfTickMarks = 0
                slider.allowsTickMarkValuesOnly = false
            }
        }
        slider.onChange = { slider in
            var value = slider.doubleValue
            if let step, step > 0 {
                value = (value / step).rounded() * step
            }
            label.stringValue = format(value)
            set(value)
        }
        slider.refresh = { [weak slider] in
            slider?.doubleValue = get()
            label.stringValue = format(get())
        }
        let stack = NSStackView(views: [slider, label])
        stack.spacing = 8
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        return stack
    }

    static func textField(
        placeholder: String,
        secure: Bool = false,
        width: CGFloat = 260,
        _ get: @escaping () -> String,
        _ set: @escaping (String) -> Void
    ) -> NSTextField {
        let field: BoundTextField = secure ? BoundSecureTextField() : BoundTextField()
        field.placeholderString = placeholder
        field.stringValue = get()
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.onChange = { set($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        field.refresh = { [weak field] in field?.stringValue = get() }
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// Like `popup`, for long lists: type to find, and the list opens at a fixed height.
    static func searchableChoice<Value: Equatable>(
        _ options: [(String, Value)],
        _ get: @escaping () -> Value,
        _ set: @escaping (Value) -> Void
    ) -> NSView {
        let box = SearchableChoice()
        box.setOptions(options.map(\.0), selected: options.firstIndex { $0.1 == get() } ?? 0)
        box.onSelect = { index in
            if options.indices.contains(index) { set(options[index].1) }
        }
        box.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let holder = RefreshableHolder()
        holder.refresh = { [weak box] in box?.select(index: options.firstIndex { $0.1 == get() } ?? 0, notify: false) }
        holder.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            box.topAnchor.constraint(equalTo: holder.topAnchor),
            box.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        holder.translatesAutoresizingMaskIntoConstraints = false
        return holder
    }

    /// Colour picker bound to a "#RRGGBB" string.
    static func colorWell(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> NSColorWell {
        // The compact style: a colour swatch with a small menu, not the large white square.
        let well = BoundColorWell(style: .minimal)
        well.color = NSColor(hex: get()) ?? .white
        well.onChange = { set($0.color.hexString) }
        well.refresh = { [weak well] in well?.color = NSColor(hex: get()) ?? .white }
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return well
    }

    static func button(_ title: String, style: NSButton.BezelStyle = .push, action: @escaping () -> Void) -> NSButton {
        let button = BoundButton(title: title, target: nil, action: nil)
        button.bezelStyle = style
        button.controlSize = .regular
        button.onClick = action
        return button
    }

    static func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    static func hStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}

/// Rounded, softly filled background that groups rows (System Settings style).
final class SectionBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        if #available(macOS 14.0, *) {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}

/// A control that can re-read its value from the settings store (e.g. after "Reset").
@MainActor
protocol Refreshable: AnyObject {
    var refresh: (() -> Void)? { get }
}

final class BoundSwitch: NSSwitch, Refreshable {
    var onChange: ((NSSwitch) -> Void)?
    var refresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange?(self)
    }
}

final class BoundPopUp: NSPopUpButton, Refreshable {
    var onChange: ((NSPopUpButton) -> Void)?
    var refresh: (() -> Void)?

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange?(self)
    }
}

final class BoundSlider: NSSlider, Refreshable {
    var onChange: ((NSSlider) -> Void)?
    var refresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange?(self)
    }
}

class BoundTextField: NSTextField, Refreshable, NSTextFieldDelegate {
    var onChange: ((NSTextField) -> Void)?
    var refresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onChange?(self)
    }
}

final class BoundSecureTextField: BoundTextField {
    override class var cellClass: AnyClass? {
        get { NSSecureTextFieldCell.self }
        set {}
    }
}

final class RefreshableHolder: NSView, Refreshable {
    var refresh: (() -> Void)?
}

final class BoundColorWell: NSColorWell, Refreshable {
    var onChange: ((NSColorWell) -> Void)?
    var refresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange?(self)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

final class BoundButton: NSButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
    }

    @objc private func clicked() {
        onClick?()
    }
}

extension NSView {
    /// Calls `refresh` on every bound control below this view.
    @MainActor
    func refreshBoundControls() {
        if let control = self as? Refreshable {
            control.refresh?()
        }
        for subview in subviews {
            subview.refreshBoundControls()
        }
    }
}
