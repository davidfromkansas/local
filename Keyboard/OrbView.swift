import MetalKit
import SwiftUI
import TakiCore

/// The voice orb shown in place of the letter keys while dictating.
struct OrbView: UIViewRepresentable {
    let model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbRenderer.device)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 120
        view.isUserInteractionEnabled = false
        context.coordinator.renderer?.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.reduceMotion = reduceMotion
        context.coordinator.renderer?.dark = colorScheme == .dark
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator {
        let renderer: OrbRenderer?
        init(model: KeyboardModel) { renderer = OrbRenderer(model: model) }
    }

    static var isSupported: Bool { OrbRenderer.device != nil }
}

/// Drives the orb shader each frame from the latest voice spectrum, smoothed like a 2D visualizer
/// (fast attack, slow release) so it rises with speech and melts back down in pauses.
final class OrbRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    /// 384 × 192 grid ≈ 150k vertices. The GPU keeps every transformed vertex of a frame in memory that counts
    /// against the keyboard's 177 MB limit: the old 1024 × 1000 grid (2M vertices) got the keyboard killed on iPhone.
    private let cols: UInt32 = 384
    private let rows: UInt32 = 192

    private weak var model: KeyboardModel?
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    var reduceMotion = false
    var dark = false

    private var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var level: Float = 0
    private var speaking: Float = 0
    private var calm: Float = 0
    private var time: Float = 0
    private var lastFrame = CACurrentMediaTime()

    init?(model: KeyboardModel) {
        guard let device = Self.device,
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: OrbRenderer.self)) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orb_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "orb_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        self.model = model
        self.queue = queue
        self.pipeline = pipeline
        self.depth = depth
    }

    func attach(to view: MTKView) {
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastFrame))
        lastFrame = now
        advance(dt: dt)

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        var uniforms = makeUniforms(aspect: Float(size.width / max(1, size.height)))
        var voice = voiceRanges()
        Self.latest = (uniforms, voice)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        encoder.setVertexBytes(&voice, length: MemoryLayout<SIMD3<Float>>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(cols + 1) * 2, instanceCount: Int(rows))
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Smoothing rates are per 60 Hz frame; `ease` rescales them so 120 Hz ProMotion feels the same.
    private func advance(dt: Float) {
        func ease(_ rate: Float) -> Float { 1 - pow(1 - rate, dt * 60) }
        let target = model?.spectrum ?? []
        for i in bands.indices {
            let goal = i < target.count ? target[i] : 0
            bands[i] += (goal - bands[i]) * ease(goal > bands[i] ? 0.55 : 0.12)
        }
        let loud = pow(model?.level ?? 0, 0.6)  // lift soft sounds (whispers) more than loud ones
        level += (loud - level) * ease(loud > level ? 0.5 : 0.1)
        let voiced: Float = loud > Self.talkingThreshold ? 1 : 0
        speaking += (voiced - speaking) * ease(voiced > speaking ? 0.35 : 0.04)
        let settling: Float = model?.state == .processing ? 1 : 0
        calm += (settling - calm) * ease(0.08)
        time += dt * (reduceMotion ? 0.35 : 1) * (1 + speaking * 0.6)
    }

    /// Low / mid / high averages of the smoothed bands.
    private func voiceRanges() -> SIMD3<Float> {
        let third = bands.count / 3
        func mean(_ range: Range<Int>) -> Float { bands[range].reduce(0, +) / Float(max(1, range.count)) }
        return SIMD3(mean(0..<third), mean(third..<(2 * third)), mean((2 * third)..<bands.count))
    }

    /// The pose drawn last, so the morph overlay can trace the live orb's exact outline.
    nonisolated(unsafe) static var latest: (uniforms: OrbUniforms, voice: SIMD3<Float>)?

    /// Level (after the 0.6 curve) above which the orb switches to its talking motion.
    static let talkingThreshold: Float = 0.3
    private static let eyeDistance: Float = 4.3
    private static let fovY: Float = 0.62
    static func orbScale(calm: Float, speaking: Float = 0) -> Float { 1.12 - 0.14 * calm - 0.1 * speaking }

    /// On-screen radius (points) of the resting orb in a view `height` points tall.
    static func silhouetteRadius(height: Float, calm: Float) -> Float {
        height / 2 * tan(asin(orbScale(calm: calm) / eyeDistance)) / tan(fovY / 2)
    }

    private func makeUniforms(aspect: Float) -> OrbUniforms {
        let eye = SIMD3<Float>(0, 0, Self.eyeDistance)
        let projection = Self.perspective(fovY: Self.fovY, aspect: aspect, near: 0.1, far: 20)
        let viewMatrix = Self.translation(-eye)
        let spin = reduceMotion ? 0 : time * 0.12
        let model = Self.rotationX(0.35) * Self.rotationY(spin) * Self.scale(Self.orbScale(calm: calm, speaking: speaking))
        return OrbUniforms(viewProjection: projection * viewMatrix, model: model, time: time, level: level,
                           speaking: speaking, calm: calm, cols: cols, rows: rows,
                           motion: reduceMotion ? 0.5 : 1, dark: dark ? 1 : 0)
    }

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1)))
    }

    private static func rotationY(_ a: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1)))
    }

    private static func rotationX(_ a: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0), SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)))
    }

    private static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }
}

/// Must match `OrbUniforms` in Orb.metal.
struct OrbUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var time: Float
    var level: Float
    var speaking: Float
    var calm: Float
    var cols: UInt32
    var rows: UInt32
    var motion: Float
    var dark: Float
}

/// The idle mic bar: a lava lamp lit with the orb's glossy purple material (`lava_fragment` in Orb.metal).
struct LavaView: UIViewRepresentable {
    /// Stops drawing while the bar is hidden behind the orb.
    var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbRenderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator?.reduceMotion = reduceMotion
        view.isPaused = paused
    }

    func makeCoordinator() -> LavaRenderer? { LavaRenderer() }
}

final class LavaRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    var reduceMotion = false

    init?(device: MTLDevice? = OrbRenderer.device) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: LavaRenderer.self)) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lava_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lava_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let time = LavaClock.advance(reduceMotion: reduceMotion)
        let size = view.drawableSize
        guard view.bounds.width > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(size.width / view.bounds.width)
        var uniforms = LavaUniforms(size: SIMD2(Float(size.width), Float(size.height)) / scale, time: time, scale: scale)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LavaUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Must match `LavaUniforms` in Orb.metal.
struct LavaUniforms {
    var size: SIMD2<Float>
    var time: Float
    var scale: Float
}

/// One lava clock shared by the bar and the morph overlay, so the overlay starts (and ends) exactly where the bar is.
enum LavaClock {
    nonisolated(unsafe) private static var time: Float = 0
    nonisolated(unsafe) private static var last = CACurrentMediaTime()

    static func advance(reduceMotion: Bool) -> Float {
        let now = CACurrentMediaTime()
        time += Float(min(0.1, now - last)) * (reduceMotion ? 0.3 : 1.95)
        last = now
        return time
    }
}

/// One run of the bar ⇄ orb hand-off.
struct LavaMorph: Equatable {
    static let duration: CFTimeInterval = 0.8
    let id: Int
    let start: CFTimeInterval
    /// true: bar → orb; false: orb → bar.
    let forward: Bool
    /// How settled (shrunk) the orb is at the orb end.
    let calm: Float
}

/// Full-keyboard overlay that plays `morph_fragment` for the duration of a `LavaMorph`.
struct MorphView: UIViewRepresentable {
    let morph: LavaMorph
    let bar: CGRect
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: OrbRenderer.device)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        update(context.coordinator)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) { update(context.coordinator) }

    private func update(_ renderer: MorphRenderer?) {
        renderer?.morph = morph
        renderer?.bar = bar
        renderer?.dark = colorScheme == .dark
    }

    func makeCoordinator() -> MorphRenderer? { MorphRenderer() }
}

final class MorphRenderer: NSObject, MTKViewDelegate {
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device = OrbRenderer.device,
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: MorphRenderer.self)) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lava_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "morph_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()

    /// Builds the pipeline ahead of the first tap so the overlay's first frame isn't late.
    static func warmUp() { _ = pipeline }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    var morph: LavaMorph?
    var bar: CGRect = .zero
    var dark = false

    init?(device: MTLDevice? = OrbRenderer.device) {
        guard let device, let queue = device.makeCommandQueue(), let pipeline = Self.pipeline else { return nil }
        self.queue = queue
        self.pipeline = pipeline
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let lavaTime = LavaClock.advance(reduceMotion: false)
        guard let morph, view.bounds.width > 0, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let linear = Float(min(1, max(0, (CACurrentMediaTime() - morph.start) / LavaMorph.duration)))
        let bounds = view.bounds
        let scale = Float(view.drawableSize.width / bounds.width)
        let height = Float(bounds.height)
        let orb = OrbRenderer.latest
        let calm = orb?.uniforms.calm ?? morph.calm
        var uniforms = MorphUniforms(
            orbModel: orb?.uniforms.model ?? simd_float4x4(diagonal: SIMD4(OrbRenderer.orbScale(calm: calm), OrbRenderer.orbScale(calm: calm), OrbRenderer.orbScale(calm: calm), 1)),
            bar: SIMD4(Float(bar.minX), Float(bar.minY), Float(bar.width), Float(bar.height)),
            voice: SIMD4(orb?.voice ?? .zero, 0),
            size: SIMD2(Float(bounds.width), height),
            center: SIMD2(Float(bounds.midX), Float(bounds.midY)),
            scale: scale, lavaTime: lavaTime, progress: morph.forward ? linear : 1 - linear, calm: calm,
            dark: dark ? 1 : 0, corner: 10,
            orbTime: orb?.uniforms.time ?? 0, speaking: orb?.uniforms.speaking ?? 0,
            level: orb?.uniforms.level ?? 0, motion: orb?.uniforms.motion ?? 1,
            radius: OrbRenderer.silhouetteRadius(height: height, calm: calm), pad: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MorphUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// Must match `MorphUniforms` in Orb.metal.
struct MorphUniforms {
    var orbModel: simd_float4x4
    var bar: SIMD4<Float>
    var voice: SIMD4<Float>
    var size: SIMD2<Float>
    var center: SIMD2<Float>
    var scale: Float
    var lavaTime: Float
    var progress: Float
    var calm: Float
    var dark: Float
    var corner: Float
    var orbTime: Float
    var speaking: Float
    var level: Float
    var motion: Float
    var radius: Float
    var pad: Float
}
