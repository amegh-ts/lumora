import AppKit

enum EqualizerPreset: String, CaseIterable {
    case flat = "Flat"
    case bassBoost = "Bass Boost"
    case trebleBoost = "Treble Boost"
    case vocal = "Vocal"
    case rock = "Rock"
    case pop = "Pop"
    case classical = "Classical"
    case loudness = "Loudness"
    case night = "Night (soft)"

    static let frequencies = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var gains: [Double] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        case .vocal: return [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1]
        case .rock: return [4, 3, 2, 0, -1, -1, 1, 2, 3, 4]
        case .pop: return [-1, 1, 3, 4, 3, 1, 0, -1, -1, -1]
        case .classical: return [3, 2, 1, 0, 0, 0, -1, -1, 1, 2]
        case .loudness: return [5, 4, 1, 0, -1, -1, 0, 1, 4, 5]
        case .night: return [-4, -3, -1, 0, 1, 1, 0, -1, -3, -4]
        }
    }

    static func matching(_ gains: [Double]) -> EqualizerPreset? {
        allCases.first { preset in zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.25 } }
    }
}

/// Ten vertical band sliders (−12…+12 dB) with frequency and gain labels.
@MainActor
final class EqualizerView: NSView, Refreshable {
    var onChange: (([Double]) -> Void)?
    var refresh: (() -> Void)?

    private var sliders: [NSSlider] = []
    private var gainLabels: [NSTextField] = []

    init(gains: @escaping () -> [Double]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.spacing = 4
        columns.translatesAutoresizingMaskIntoConstraints = false
        for (index, frequency) in EqualizerPreset.frequencies.enumerated() {
            let gain = NSTextField(labelWithString: "0")
            gain.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            gain.textColor = .secondaryLabelColor
            gain.alignment = .center
            let slider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: self, action: #selector(sliderMoved(_:)))
            slider.isVertical = true
            slider.controlSize = .small
            slider.tag = index
            slider.isContinuous = true
            slider.setAccessibilityLabel("\(frequency) hertz")
            slider.heightAnchor.constraint(equalToConstant: 120).isActive = true
            let label = NSTextField(labelWithString: frequency)
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let column = NSStackView(views: [gain, slider, label])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 4
            columns.addArrangedSubview(column)
            sliders.append(slider)
            gainLabels.append(gain)
        }
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            columns.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            columns.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        refresh = { [weak self] in self?.show(gains()) }
        show(gains())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ gains: [Double]) {
        for (index, slider) in sliders.enumerated() where gains.indices.contains(index) {
            slider.doubleValue = gains[index]
            gainLabels[index].stringValue = Self.format(gains[index])
        }
    }

    private static func format(_ gain: Double) -> String {
        let rounded = (gain * 2).rounded() / 2
        return rounded == 0 ? "0" : String(format: "%+.1f", rounded)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let value = (sender.doubleValue * 2).rounded() / 2
        gainLabels[sender.tag].stringValue = Self.format(value)
        onChange?(sliders.map { ($0.doubleValue * 2).rounded() / 2 })
    }
}
