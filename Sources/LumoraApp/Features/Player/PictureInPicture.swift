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

    func layout() {
        displayLayer.frame = hostView.bounds
    }

    /// `dryRun` (DEBUG tests): render frames but don't open the floating window.
    func start(dryRun: Bool = false) {
        guard !isActive, Self.isSupported, engine.hasMedia else { return }
        isActive = true
        onActiveChange?(true)
        hostView.isHidden = false
        layout()
        syncTimebase()

        let renderer = SoftwareFrameRenderer(mpv: engine.handle, layer: displayLayer)
        self.renderer = renderer
        renderer.start(size: CGSize(width: 960, height: 540))
        engine.beginSoftwareOutput()
        if dryRun { return }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        // PiP can start once the layer has shown a frame; give up after a few seconds.
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.startWhenPossible() }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.controller?.isPictureInPictureActive != true else { return }
                self.finish()
            }
        }
        startWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func startWhenPossible() {
        guard isActive, let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        startWork?.cancel()
        controller.startPictureInPicture()
    }

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
        finish()
    }

    /// Back to the Metal output and the normal window.
    private func finish() {
        guard isActive else { return }
        isActive = false
        startWork?.cancel()
        possibleObservation = nil
        controller = nil
        renderer?.stop()
        renderer = nil
        engine.endSoftwareOutput()
        displayLayer.flushAndRemoveImage()
        hostView.isHidden = true
        onActiveChange?(false)
    }

    /// Keeps the PiP progress bar in step with mpv (time, pause and speed).
    func syncTimebase() {
        guard let timebase else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: engine.currentTime, preferredTimescale: 600))
        CMTimebaseSetRate(timebase, rate: engine.isPlaying ? Double(engine.rate) : 0)
        controller?.invalidatePlaybackState()
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { onRestore?() }
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            playing ? engine.play() : engine.pause()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            guard engine.duration > 0, !engine.isLive else {
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            return CMTimeRange(start: .zero, duration: CMTime(seconds: engine.duration, preferredTimescale: 600))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !engine.isPlaying }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        MainActor.assumeIsolated {
            renderer?.resize(to: CGSize(width: CGFloat(newRenderSize.width), height: CGFloat(newRenderSize.height)))
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            engine.skip(skipInterval.seconds)
        }
        completionHandler()
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
    private var lastBuffer: CVPixelBuffer?

    init(mpv: OpaquePointer, layer: AVSampleBufferDisplayLayer) {
        self.mpv = mpv
        self.layer = layer
    }

    func start(size: CGSize) {
        queue.sync {
            self.size = Self.bounded(size)
            let apiType = strdup("sw")
            defer { free(apiType) }
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param()
            ]
            var created: OpaquePointer?
            guard mpv_render_context_create(&created, mpv, &params) >= 0, let created else { return }
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
        DispatchQueue.main.async {
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sample)
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
