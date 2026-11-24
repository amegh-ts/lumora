import AppKit

@MainActor
final class TimelineView: NSView {
    var duration: TimeInterval = 0 {
        didSet {
            if duration != oldValue { needsDisplay = true }
        }
    }
    /// Redraws only when the progress moves by at least one physical pixel.
    var currentTime: TimeInterval = 0 {
        didSet {
            guard !isDragging else { return }
            let scale = window?.backingScaleFactor ?? 2
            if abs(x(for: currentTime) - x(for: oldValue)) * scale >= 1 {
                needsDisplay = true
            }
        }
    }
    var loopA: TimeInterval? {
        didSet { needsDisplay = true }
    }
    var loopB: TimeInterval? {
        didSet { needsDisplay = true }
    }
    var chapters: [Chapter] = [] {
        didSet { needsDisplay = true }
    }
    /// Already-downloaded parts of a stream.
    var buffered: [ClosedRange<TimeInterval>] = [] {
        didSet {
            if buffered != oldValue { needsDisplay = true }
        }
    }

    var onScrub: ((TimeInterval, Bool) -> Void)?
    var onHover: ((TimeInterval?, CGFloat) -> Void)?

    private let inset: CGFloat = 7
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isDragging = false
    private var dragTime: TimeInterval = 0
    private var hoverX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback position")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard duration > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoverX = x
        onHover?(time(at: x), x)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverX = nil
        if !isDragging {
            onHover?(nil, 0)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        isDragging = true
        scrub(with: event, finished: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        scrub(with: event, finished: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        scrub(with: event, finished: true)
        isDragging = false
        if !isHovering {
            onHover?(nil, 0)
        }
    }

    override func accessibilityValue() -> Any? {
        duration > 0
            ? "\(TimeFormatter.string(currentTime)) of \(TimeFormatter.string(duration))"
            : TimeFormatter.string(currentTime)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformIncrement() -> Bool {
        guard duration > 0 else { return false }
        onScrub?(min(duration, currentTime + 10), true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard duration > 0 else { return false }
        onScrub?(max(0, currentTime - 10), true)
        return true
    }

    private func scrub(with event: NSEvent, finished: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        dragTime = time(at: x)
        hoverX = x
        onScrub?(dragTime, finished)
        onHover?(dragTime, x)
        needsDisplay = true
    }

    private func time(at x: CGFloat) -> TimeInterval {
        let width = max(bounds.width - inset * 2, 1)
        let fraction = min(max((x - inset) / width, 0), 1)
        return Double(fraction) * duration
    }

    private func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return inset }
        let fraction = CGFloat(min(max(time / duration, 0), 1))
        return inset + fraction * (bounds.width - inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isHovering || isDragging
        let height: CGFloat = active ? 6 : 4
        let track = NSRect(x: inset, y: bounds.midY - height / 2, width: bounds.width - inset * 2, height: height)
        let radius = height / 2

        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        if duration > 0 {
            NSColor.white.withAlphaComponent(0.22).setFill()
            for range in buffered {
                let start = x(for: range.lowerBound)
                let end = x(for: range.upperBound)
                guard end - start >= 1 else { continue }
                let rect = NSRect(x: start, y: track.minY, width: end - start, height: height)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }

        if let hoverX, active, !isDragging {
            let hoverRect = NSRect(x: track.minX, y: track.minY, width: max(0, min(hoverX, track.maxX) - track.minX), height: height)
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: hoverRect, xRadius: radius, yRadius: radius).fill()
        }

        if let loopA {
            let start = x(for: loopA)
            let end = loopB.map { x(for: $0) } ?? start + 2
            let loopRect = NSRect(x: start, y: track.minY - 2, width: max(2, end - start), height: height + 4)
            NSColor.systemYellow.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: loopRect, xRadius: 2, yRadius: 2).fill()
        }

        let shown = isDragging ? dragTime : currentTime
        let progressX = x(for: shown)
        let progressRect = NSRect(x: track.minX, y: track.minY, width: max(0, progressX - track.minX), height: height)
        HUD.accent.setFill()
        NSBezierPath(roundedRect: progressRect, xRadius: radius, yRadius: radius).fill()

        if duration > 0 {
            NSColor.white.withAlphaComponent(0.55).setFill()
            for chapter in chapters where chapter.time > 0.5 && chapter.time < duration - 0.5 {
                let cx = x(for: chapter.time)
                NSRect(x: cx - 1, y: track.minY, width: 2, height: height).fill()
            }
        }

        if active, duration > 0 {
            let knobSize: CGFloat = 13
            let knob = NSRect(x: progressX - knobSize / 2, y: bounds.midY - knobSize / 2, width: knobSize, height: knobSize)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 3
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
        }
    }
}
