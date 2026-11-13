import MetalKit
import TakiCore

/// What the orb listens to. The keyboard and the Mac overlay each feed it their own mic readings.
protocol OrbVoiceSource: AnyObject {
    /// `SpectrumAnalyzer` bands, 0…1.
    var spectrum: [Float] { get }
    /// Mic level, 0…1.
    var level: Float { get }
    /// Transcribing: the orb calms down and shrinks a little.
    var isSettling: Bool { get }
}

/// Drives the orb shader each frame from the latest voice spectrum, smoothed like a 2D visualizer
/// (fast attack, slow release) so it rises with speech and melts back down in pauses.
final class OrbRenderer: NSObject, MTKViewDelegate {
    static let device = MTLCreateSystemDefaultDevice()
    /// 1024 × 1000 grid ≈ 1M vertices.
    private let cols: UInt32 = 1024
    private let rows: UInt32 = 1000

    private weak var model: (any OrbVoiceSource)?
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

    init?(model: any OrbVoiceSource) {
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
        let loud = model?.level ?? 0
        level += (loud - level) * ease(loud > level ? 0.5 : 0.1)
        let voiced: Float = loud > 0.3 ? 1 : 0
        speaking += (voiced - speaking) * ease(voiced > speaking ? 0.35 : 0.04)
        let settling: Float = model?.isSettling == true ? 1 : 0
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

    private static let eyeDistance: Float = 4.3
    private static let fovY: Float = 0.62
    static func orbScale(calm: Float) -> Float { 1.12 - 0.14 * calm }

    /// On-screen radius (points) of the resting orb in a view `height` points tall.
    static func silhouetteRadius(height: Float, calm: Float) -> Float {
        height / 2 * tan(asin(orbScale(calm: calm) / eyeDistance)) / tan(fovY / 2)
    }

    private func makeUniforms(aspect: Float) -> OrbUniforms {
        let eye = SIMD3<Float>(0, 0, Self.eyeDistance)
        let projection = Self.perspective(fovY: Self.fovY, aspect: aspect, near: 0.1, far: 20)
        let viewMatrix = Self.translation(-eye)
        let spin = reduceMotion ? 0 : time * 0.12
        let model = Self.rotationX(0.35) * Self.rotationY(spin) * Self.scale(Self.orbScale(calm: calm))
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
