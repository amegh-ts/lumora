import AVFoundation
import Accelerate
import AVKit
import AppKit
import CMPV
import CoreMedia
import CoreImage
import CoreVideo

/// System Picture in Picture for the libmpv engine.
///
/// mpv renders through its own Metal output, which macOS can't lift into a PiP window. While PiP
/// is open, mpv switches to its render API in software mode at the PiP window's size; each frame
/// goes into a CVPixelBuffer and onto an AVSampleBufferDisplayLayer that AVKit shows floating.
/// Leaving PiP switches back to the Metal output.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let engine: PlaybackEngine
    let hostView = NSView()
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var renderer: SoftwareFrameRenderer?
    private var possibleObservation: NSKeyValueObservation?
    private var timebase: CMTimebase?
    private var startWork: DispatchWorkItem?
    nonisolated private let snapshot = PlaybackSnapshot()

    var onActiveChange: ((Bool) -> Void)?
    var onRestore: (() -> Void)?
    private(set) var isActive = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init()
        hostView.wantsLayer = true
        hostView.layer = CALayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        hostView.layer?.addSublayer(displayLayer)
        hostView.isHidden = true
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
        timebase = created
        displayLayer.controlTimebase = created
    }

    /// AVKit sizes its PiP host from this layer; a zero or NaN size makes it crash, so never
    /// leave it empty.
    func layout() {
        let bounds = hostView.bounds
        let valid = bounds.width >= 1 && bounds.height >= 1 && bounds.width.isFinite && bounds.height.isFinite
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = valid ? bounds : CGRect(x: 0, y: 0, width: 480, height: 270)
        CATransaction.commit()
    }

    /// `dryRun` (DEBUG tests): render frames but don't open the floating window.
    func start(dryRun: Bool = false) {
        guard !isActive, Self.isSupported, engine.hasMedia else { return }
        isActive = true
        onActiveChange?(true)
        hostView.isHidden = false
        hostView.superview?.layoutSubtreeIfNeeded()
        layout()
        syncTimebase()

        let renderer = SoftwareFrameRenderer(mpv: engine.handle, layer: displayLayer)
        self.renderer = renderer
        // AVKit derives its window geometry from the video's size; with no frame yet that's 0/0
        // and it crashes on a NaN frame. Create the controller once a frame is on the layer.
        if !dryRun {
            renderer.onFirstFrame = { [weak self] in
                MainActor.assumeIsolated { self?.createController() }
            }
        }
        // Without a render context mpv's libmpv output can't start; stay on Metal.
        guard renderer.start(size: CGSize(width: 960, height: 540)) else {
            self.renderer = nil
            isActive = false
            hostView.isHidden = true
            onActiveChange?(false)
            return
        }
        engine.beginSoftwareOutput()
        if dryRun { return }

        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controller?.isPictureInPictureActive != true else { return }
                self.finish()
            }
        }
        startWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func createController() {
        guard isActive, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        possibleObservation = Self.observePossible(controller) { [weak self] in self?.startWhenPossible() }
    }

    /// KVO may report from any thread; the handler is built outside the main actor and hops to it.
    nonisolated private static func observePossible(
        _ controller: AVPictureInPictureController, _ onMain: @escaping @MainActor @Sendable () -> Void
    ) -> NSKeyValueObservation {
        controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { onMain() } }
        }
    }

    /// Runs PiP work on the main actor: directly when AVKit calls on the main thread (it
    /// documents that), via the main queue otherwise, instead of trapping.
    nonisolated private func onMain(_ work: @escaping @MainActor @Sendable (PictureInPicture) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work(self) } }
        }
    }

    private func startWhenPossible() {
        guard isActive, let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        startWork?.cancel()
        controller.startPictureInPicture()
    }

    #if DEBUG
        /// #50 test: AVKit's questions and commands, asked from a background queue.
        func debugCallbacksFromBackground(_ report: @escaping @Sendable (String) -> Void) {
            syncTimebase()
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            nonisolated(unsafe) let controller = AVPictureInPictureController(contentSource: source)
            DispatchQueue.global().async { [self] in
                let range = pictureInPictureControllerTimeRangeForPlayback(controller)
                let paused = pictureInPictureControllerIsPlaybackPaused(controller)
                pictureInPictureController(controller, setPlaying: false)
                pictureInPictureController(controller, didTransitionToRenderSize: CMVideoDimensions(width: 640, height: 360))
                pictureInPictureController(controller, skipByInterval: CMTime(seconds: 15, preferredTimescale: 1)) {
                    report("skip completion ran on main=\(Thread.isMainThread)")
                }
                report("background: duration=\(range.duration.seconds) paused=\(paused)")
            }
        }
    #endif

    var framesRendered: Int { renderer?.frameCount ?? 0 }
    func debugSaveFrame(to url: URL) { renderer?.saveLastFrame(to: url) }

    func stop() {
        guard isActive else { return }
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            finish()
        }
    }

    /// Window closing: end PiP now, before the engine is destroyed.
    func tearDown() {
        controller?.stopPictureInPicture()
        // The engine is about to be destroyed: don't start a new Metal output for a closing window.
        finish(restoreOutput: false)
    }

    /// Back to the Metal output and the normal window.
    private func finish(restoreOutput: Bool = true) {
        guard isActive else { return }
        isActive = false
        startWork?.cancel()
        possibleObservation = nil
        controller = nil
        // Switch mpv back to Metal before freeing the software context, so the libmpv output
        // never runs without one (that failure used to look like "Metal unavailable").
        if restoreOutput {
            engine.endSoftwareOutput()
        }
        renderer?.stop()
        renderer = nil
        displayLayer.flushAndRemoveImage()
        hostView.isHidden = true
        onActiveChange?(false)
    }

    /// Keeps the PiP progress bar in step with mpv (time, pause and speed).
    func syncTimebase() {
        snapshot.update(duration: engine.duration, live: engine.isLive, playing: engine.isPlaying)
        guard let timebase else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: engine.currentTime, preferredTimescale: 600))
        CMTimebaseSetRate(timebase, rate: engine.isPlaying ? Double(engine.rate) : 0)
        controller?.invalidatePlaybackState()
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onMain { $0.finish() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        onMain { $0.finish() }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onMain { $0.onRestore?() }
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain { pip in
            playing ? pip.engine.play() : pip.engine.pause()
        }
    }

    /// Answered from a snapshot so it works from any thread.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let (duration, live, _) = snapshot.read()
        guard duration > 0, !live else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !snapshot.read().playing
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        let size = CGSize(width: CGFloat(newRenderSize.width), height: CGFloat(newRenderSize.height))
        onMain { $0.renderer?.resize(to: size) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        let seconds = skipInterval.seconds
        nonisolated(unsafe) let completion = completionHandler
        onMain { pip in
            pip.engine.skip(seconds)
            // AVKit expects the timebase at the new position when the completion runs.
            if let timebase = pip.timebase {
                let target = max(0, pip.engine.currentTime + seconds)
                let bounded = pip.engine.duration > 0 ? min(target, pip.engine.duration) : target
                CMTimebaseSetTime(timebase, time: CMTime(seconds: bounded, preferredTimescale: 600))
            }
            completion()
        }
    }
}

/// Duration, live and playing state for AVKit's questions, readable from any thread.
private final class PlaybackSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: TimeInterval = 0
    private var live = false
    private var playing = false

    func update(duration: TimeInterval, live: Bool, playing: Bool) {
        lock.withLock {
            self.duration = duration
            self.live = live
            self.playing = playing
        }
    }

    func read() -> (duration: TimeInterval, live: Bool, playing: Bool) {
        lock.withLock { (duration, live, playing) }
    }
}

/// Drives mpv's software renderer on its own queue and enqueues each frame on the display layer.
final class SoftwareFrameRenderer: @unchecked Sendable {
    private let mpv: OpaquePointer
    private let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "com.lumora.pip-render", qos: .userInteractive)
    private var context: OpaquePointer?
    private var box: Unmanaged<SoftwareFrameRenderer>?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var size = CGSize(width: 960, height: 540)
    private var format: CMVideoFormatDescription?
    private(set) var frameCount = 0
    /// Called on the main thread after the first frame has been enqueued.
    var onFirstFrame: (@Sendable () -> Void)?
    private var lastBuffer: CVPixelBuffer?

    init(mpv: OpaquePointer, layer: AVSampleBufferDisplayLayer) {
        self.mpv = mpv
        self.layer = layer
    }

    @discardableResult
    func start(size: CGSize) -> Bool {
        queue.sync {
            self.size = Self.bounded(size)
            let apiType = strdup("sw")
            defer { free(apiType) }
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param()
            ]
            var created: OpaquePointer?
            guard mpv_render_context_create(&created, mpv, &params) >= 0, let created else { return false }
            context = created
            let retained = Unmanaged.passRetained(self)
            box = retained
            mpv_render_context_set_update_callback(
                created,
                { pointer in
                    guard let pointer else { return }
                    let renderer = Unmanaged<SoftwareFrameRenderer>.fromOpaque(pointer).takeUnretainedValue()
                    renderer.queue.async { renderer.renderIfNeeded() }
                }, retained.toOpaque())
            return true
        }
    }

    /// DEBUG: writes the most recent frame as a PNG.
    func saveLastFrame(to url: URL) {
        queue.sync {
            guard let lastBuffer else { return }
            let image = CIImage(cvPixelBuffer: lastBuffer)
            let rep = NSCIImageRep(ciImage: image)
            let picture = NSImage(size: rep.size)
            picture.addRepresentation(rep)
            if let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try? png.write(to: url)
            }
        }
    }

    func resize(to newSize: CGSize) {
        queue.async { self.size = Self.bounded(newSize) }
    }

    /// Frees the render context; mpv then turns this output off.
    func stop() {
        queue.sync {
            guard let context else { return }
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
            self.context = nil
            box?.release()
            box = nil
            pool = nil
        }
    }

    /// PiP windows are small; rendering above 1280×720 only costs CPU.
    private static func bounded(_ size: CGSize) -> CGSize {
        let scale = min(1, 1280 / max(size.width, 1), 720 / max(size.height, 1))
        return CGSize(width: max(64, (size.width * scale).rounded()), height: max(36, (size.height * scale).rounded()))
    }

    private func renderIfNeeded() {
        guard let context else { return }
        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0, let buffer = makeBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        var dimensions: [Int32] = [Int32(CVPixelBufferGetWidth(buffer)), Int32(CVPixelBufferGetHeight(buffer))]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        let formatName = strdup("bgr0")
        let pixels = CVPixelBufferGetBaseAddress(buffer)
        dimensions.withUnsafeMutableBytes { sizePointer in
            withUnsafeMutablePointer(to: &stride) { stridePointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePointer.baseAddress),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatName)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                    mpv_render_param()
                ]
                mpv_render_context_render(context, &params)
            }
        }
        free(formatName)
        // "bgr0" leaves the fourth byte undefined (usually 0 = transparent); make every pixel opaque.
        var image = vImage_Buffer(
            data: pixels, height: vImagePixelCount(dimensions[1]), width: vImagePixelCount(dimensions[0]), rowBytes: stride)
        vImageOverwriteChannelsWithScalar_ARGB8888(255, &image, &image, 0x1, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frameCount += 1
        lastBuffer = buffer
        guard let sample = makeSample(buffer) else { return }
        let layer = self.layer
        let first = frameCount == 1 ? onFirstFrame : nil
        DispatchQueue.main.async {
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sample)
            first?()
        }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
            format = nil
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makeSample(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return nil }
        // Show each frame as soon as it arrives; mpv already timed it.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
