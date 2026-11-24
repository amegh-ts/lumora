import AppKit

@MainActor
protocol PlayerRootViewDelegate: AnyObject {
    func playerRootViewDidMoveMouse(_ view: PlayerRootView)
    func playerRootViewDidSingleClick(_ view: PlayerRootView)
    func playerRootViewDidDoubleClick(_ view: PlayerRootView)
    func playerRootView(_ view: PlayerRootView, didScrollX x: CGFloat, y: CGFloat, flags: NSEvent.ModifierFlags)
    func playerRootView(_ view: PlayerRootView, handleKeyDown event: NSEvent) -> Bool
    func playerRootView(_ view: PlayerRootView, didReceiveURLs urls: [URL])
}

final class PlayerRootView: NSView {
    weak var eventDelegate: PlayerRootViewDelegate?

    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        eventDelegate?.playerRootViewDidMoveMouse(self)
    }

    override func mouseEntered(with event: NSEvent) {
        eventDelegate?.playerRootViewDidMoveMouse(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            eventDelegate?.playerRootViewDidDoubleClick(self)
        } else {
            eventDelegate?.playerRootViewDidSingleClick(self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        eventDelegate?.playerRootView(self, didScrollX: event.scrollingDeltaX, y: event.scrollingDeltaY, flags: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        let handled = eventDelegate?.playerRootView(self, handleKeyDown: event) ?? false
        if !handled {
            super.keyDown(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []
        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls.append(contentsOf: fileURLs)
        }
        if let string = pasteboard.string(forType: .string), let url = URL(string: string) {
            urls.append(url)
        }
        guard !urls.isEmpty else { return false }
        eventDelegate?.playerRootView(self, didReceiveURLs: urls)
        return true
    }
}
