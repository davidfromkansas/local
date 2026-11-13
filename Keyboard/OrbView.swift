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

extension KeyboardModel: OrbVoiceSource {
    var isSettling: Bool { state == .processing }
}
