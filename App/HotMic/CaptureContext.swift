import AVFoundation
import TakiCore
import TakiEngine

/// Runs on the real-time audio thread. Armed = buffers are dropped; capturing = they're
/// converted to 16 kHz mono Float32 and accumulated. Never touches the main actor.
nonisolated final class CaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private let store: SharedStore
    private var isCapturing = false
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var lastLevelWrite: CFAbsoluteTime = 0
    private var currentLevel: Float = 0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(store: SharedStore) {
        self.store = store
    }

    var level: Float { lock.withLock { currentLevel } }

    func install(on input: AVAudioInputNode, format: AVAudioFormat) {
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
    }

    func begin() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(16_000 * 30)
            isCapturing = true
        }
    }

    func finish() -> [Float] {
        let captured = lock.withLock {
            isCapturing = false
            currentLevel = 0
            let captured = samples
            samples = []
            return captured
        }
        store.writeLevel(0)
        return captured
    }

    var capturedSeconds: Double { lock.withLock { Double(samples.count) / 16_000 } }

    /// Copy of what's been captured from `index` on, for live transcription while still capturing.
    func samples(from index: Int) -> [Float] {
        lock.withLock { index < samples.count ? Array(samples[index...]) : [] }
    }

    /// Used by the DEBUG file feed so the keyboard waveform still moves.
    func publish(level: Float) {
        lock.withLock { currentLevel = level }
        store.writeLevel(level)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ isCapturing }), let converted = convert(buffer) else { return }
        let level = AudioLevel.normalized(rms: AudioLevel.rms(converted))
        lock.withLock {
            guard isCapturing else { return }
            samples.append(contentsOf: converted)
            currentLevel = level
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelWrite > 1.0 / 30 {
            lastLevelWrite = now
            store.writeLevel(level)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feeder = BufferFeeder(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
        guard error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// Hands one buffer to AVAudioConverter, then reports "no more data for now".
private nonisolated final class BufferFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
