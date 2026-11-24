import AppKit
import AVFoundation
import CoreImage

final class VideoView: NSView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }

    var gravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            playerLayer.videoGravity = gravity
        }
    }

    var cropRect: NSRect = .zero {
        didSet {
            updateCrop()
        }
    }

    var rotation: Double = 0 {
        didSet {
            playerLayer.transform = CATransform3DMakeRotation(CGFloat(rotation) * .pi / 180, 0, 0, 1)
        }
    }

    var brightness: Double = 0 {
        didSet { updateFilters() }
    }

    var contrast: Double = 1 {
        didSet { updateFilters() }
    }

    var saturation: Double = 1 {
        didSet { updateFilters() }
    }

    private var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("VideoView requires AVPlayerLayer")
        }
        return playerLayer
    }

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
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        self.layer = layer
        updateCrop()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    private func updateCrop() {
        if cropRect.width <= 0 || cropRect.height <= 0 {
            playerLayer.contentsRect = NSRect(x: 0, y: 0, width: 1, height: 1)
        } else {
            playerLayer.contentsRect = cropRect
        }
    }

    private func updateFilters() {
        if brightness == 0, contrast == 1, saturation == 1 {
            playerLayer.filters = nil
            return
        }
        let filter = CIFilter(
            name: "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation
            ]
        )
        playerLayer.filters = filter.map { [$0] }
    }
}
