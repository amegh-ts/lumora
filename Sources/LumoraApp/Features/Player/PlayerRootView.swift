import AppKit

@MainActor
protocol PlayerRootViewDelegate: AnyObject {
    func playerRootViewDidMoveMouse(_ view: PlayerRootView)
    func playerRootViewDidExit(_ view: PlayerRootView)
    func playerRootViewDidSingleClick(_ view: PlayerRootView)
    func playerRootViewDidDoubleClick(_ view: PlayerRootView)
    func playerRootView(_ view: PlayerRootView, didScrollX x: CGFloat, y: CGFloat, precise: Bool)
    func playerRootView(_ view: PlayerRootView, handleKeyDown event: NSEvent) -> Bool
    func playerRootView(_ view: PlayerRootView, didReceiveURLs urls: [URL])
    func playerRootView(_ view: PlayerRootView, isDropTarget: Bool)
    func playerRootViewContextMenu(_ view: PlayerRootView) -> NSMenu?
}

final class PlayerRootView: NSView {
    weak var eventDelegate: PlayerRootViewDelegate?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var trackingArea: NSTrackingArea?
    private var pendingSingleClick: DispatchWorkItem?
    private var mouseDownEvent: NSEvent?
    private var didDragWindow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    override func mouseMoved(with event: NSEvent) {
        eventDelegate?.playerRootViewDidMoveMouse(self)
    }

    override func mouseEntered(with event: NSEvent) {
        eventDelegate?.playerRootViewDidMoveMouse(self)
    }

    override func mouseExited(with event: NSEvent) {
        eventDelegate?.playerRootViewDidExit(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownEvent = event
        didDragWindow = false
        if event.clickCount == 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            eventDelegate?.playerRootViewDidDoubleClick(self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen), let mouseDownEvent, !didDragWindow else { return }
        let start = mouseDownEvent.locationInWindow
        let now = event.locationInWindow
        if hypot(now.x - start.x, now.y - start.y) > 3 {
            didDragWindow = true
            window.performDrag(with: mouseDownEvent)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !didDragWindow, event.clickCount == 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.eventDelegate?.playerRootViewDidSingleClick(self)
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = eventDelegate?.playerRootViewContextMenu(self)
        menu?.appearance = NSAppearance(named: .darkAqua)
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .ended || event.momentumPhase != [] {
            return
        }
        eventDelegate?.playerRootView(
            self,
            didScrollX: event.scrollingDeltaX,
            y: event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1),
            precise: event.hasPreciseScrollingDeltas
        )
    }

    override func keyDown(with event: NSEvent) {
        let handled = eventDelegate?.playerRootView(self, handleKeyDown: event) ?? false
        if !handled {
            super.keyDown(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        eventDelegate?.playerRootView(self, isDropTarget: true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        eventDelegate?.playerRootView(self, isDropTarget: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        eventDelegate?.playerRootView(self, isDropTarget: false)
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls.append(contentsOf: objects)
        }
        if urls.isEmpty,
           let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: string), url.scheme != nil {
            urls.append(url)
        }
        guard !urls.isEmpty else { return false }
        eventDelegate?.playerRootView(self, didReceiveURLs: urls)
        return true
    }
}
