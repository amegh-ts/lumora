import AppKit
import OpenGL.GL3
import CMPV

final class MPVVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    private let mpv: OpaquePointer
    private var renderContext: OpaquePointer?
    private var glContext: CGLContextObj?
    private var updateBox: Unmanaged<WeakBox<MPVVideoLayer>>?
    private var isTornDown = false
    var onReady: (@Sendable () -> Void)?

    init(mpv: OpaquePointer) {
        self.mpv = mpv
        super.init()
        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        guard let other = layer as? MPVVideoLayer else {
            fatalError("Unexpected layer copy")
        }
        mpv = other.mpv
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(0)
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        if let pixelFormat {
            return pixelFormat
        }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        let context = super.copyCGLContext(forPixelFormat: pixelFormat)
        var swapInterval: GLint = 1
        CGLSetParameter(context, kCGLCPSwapInterval, &swapInterval)
        glContext = context
        return context
    }

    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        !isTornDown
    }

    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        CGLSetCurrentContext(ctx)
        if renderContext == nil, !isTornDown {
            createRenderContext()
        }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        if let renderContext {
            var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
            var flip: Int32 = 1
            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flip) { flipPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param()
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
            #if DEBUG
                currentFBO = framebuffer
                probe(width: viewport[2], height: viewport[3])
            #endif
        } else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        glFlush()
    }

    #if DEBUG
        private var probeCount = 0
        private var currentFBO: GLint = 0

        private func probe(width: GLint, height: GLint) {
            guard ProcessInfo.processInfo.environment["LUMORA_GL_PROBE"] != nil else { return }
            probeCount += 1
            guard probeCount % 30 == 0 else { return }
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(currentFBO))
            var samples: [String] = []
            for (fx, fy) in [(0.25, 0.5), (0.5, 0.5), (0.75, 0.5), (0.5, 0.3), (0.5, 0.7)] {
                var pixel = [UInt8](repeating: 0, count: 4)
                glReadPixels(GLint(Double(width) * fx), GLint(Double(height) * fy), 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
                samples.append("\(pixel[0]),\(pixel[1]),\(pixel[2])")
            }
            print("[gl] fbo=\(currentFBO) frame=\(probeCount) size=\(width)x\(height) bounds=\(bounds.size) samples=\(samples)")
        }
    #endif

    private func createRenderContext() {
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var created: OpaquePointer?
        withUnsafeMutablePointer(to: &initParams) { initPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param()
            ]
            if mpv_render_context_create(&created, mpv, &params) < 0 {
                created = nil
            }
        }
        guard let created else { return }
        renderContext = created
        if let onReady {
            DispatchQueue.main.async(execute: onReady)
        }
        let box = Unmanaged.passRetained(WeakBox(self))
        updateBox = box
        mpv_render_context_set_update_callback(
            created,
            { context in
                guard let context else { return }
                let box = Unmanaged<WeakBox<MPVVideoLayer>>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    box.object?.setNeedsDisplay()
                }
            }, box.toOpaque())
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        guard let renderContext else { return }
        if let glContext {
            CGLSetCurrentContext(glContext)
        }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
        updateBox?.release()
        updateBox = nil
        CGLSetCurrentContext(nil)
    }
}

/// OpenGL fallback surface: drives mpv's render API into a CAOpenGLLayer.
final class OpenGLVideoView: NSView {
    let videoLayer: MPVVideoLayer

    init(engine: PlaybackEngine, onReady: @escaping @MainActor () -> Void) {
        videoLayer = MPVVideoLayer(mpv: engine.handle)
        super.init(frame: .zero)
        videoLayer.onReady = {
            MainActor.assumeIsolated {
                onReady()
            }
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        videoLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.display()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        videoLayer.setNeedsDisplay()
    }

    func tearDown() {
        videoLayer.tearDown()
    }
}

/// Video surface. With the Metal renderer mpv (vo=gpu-next, macvk) adds its CAMetalLayer to this
/// view; with OpenGL, or after a Metal failure, an OpenGLVideoView child takes over.
@MainActor
final class VideoView: NSView {
    private let engine: PlaybackEngine
    private var openGLView: OpenGLVideoView?
    private var attached = false

    var isUsingOpenGL: Bool { openGLView != nil }

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if engine.renderer == .openGL {
            installOpenGL { [weak engine] in engine?.renderContextReady() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !attached, engine.renderer == .metal else { return }
        attached = true
        engine.attachVideoHost(self)
    }

    /// Replaces the Metal surface with OpenGL and tells the engine once the GL context exists.
    func fallBackToOpenGL() {
        guard openGLView == nil else { return }
        engine.beginOpenGLFallback()
        installOpenGL { [weak engine] in engine?.completeOpenGLFallback() }
    }

    private func installOpenGL(onReady: @escaping @MainActor () -> Void) {
        let view = OpenGLVideoView(engine: engine, onReady: onReady)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        openGLView = view
    }

    func tearDown() {
        openGLView?.tearDown()
    }
}
