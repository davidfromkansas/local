@preconcurrency import AVFoundation
import TakiCore

/// Records 16 kHz mono Float32 while the hotkey is held. The tap runs on the real-time audio
/// thread, so this type is nonisolated and guards its state with a lock.
nonisolated final class MicCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var level: Float = 0
    private let analyzer = SpectrumAnalyzer()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var feedTimer: DispatchSourceTimer?

    /// When set (TAKI_TEST_AUDIO), this clip "plays" into the recorder in real time instead of the mic.
    /// For Macs without a microphone, like the cloud test machine.
    var testAudio: [Float]?
    /// Off for the Orb Tuner preview: it only needs the levels, not the recording.
    var keepsSamples = true
    /// Orb Tuner preview: replay the test clip forever instead of falling silent.
    var loopsTestAudio = false

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(16_000 * 60)
            analyzer.reset()
            level = 0
        }
        if let testAudio { return startFeed(testAudio) }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() -> [Float] {
        feedTimer?.cancel()
        feedTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        return lock.withLock {
            let captured = samples
            samples = []
            level = 0
            return captured
        }
    }

    /// Current level (0…1) and spectrum bands for the orb.
    func levels() -> (Float, [Float]) {
        lock.withLock { (level, analyzer.bands()) }
    }

    private func append(_ chunk: [Float]) {
        let rms = (chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, chunk.count))).squareRoot()
        lock.withLock {
            if keepsSamples { samples.append(contentsOf: chunk) }
            level = Self.normalized(rms: rms)
            analyzer.append(chunk)
        }
    }

    /// RMS → 0…1 on a -60…0 dB scale (a little more sensitive than iOS so whispers still move the orb).
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(rms) / 60))
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let feeder = BufferFeeder(buffer, then: .noDataNow)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feeder.next(status) }
        guard error == nil, let data = output.floatChannelData else { return }
        append(Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))))
    }

    private func startFeed(_ clip: [Float]) {
        var position = 0
        let loops = loopsTestAudio
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            if loops && position >= clip.count { position = 0 }
            let end = min(clip.count, position + 320)
            // After the clip ends, keep feeding near-silence until the key is released.
            let chunk = position < clip.count ? Array(clip[position..<end]) : [Float](repeating: 0, count: 320)
            position = end
            self?.append(chunk)
        }
        timer.resume()
        feedTimer = timer
    }
}

/// Hands one buffer to AVAudioConverter, then reports "no more data".
private nonisolated final class BufferFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let end: AVAudioConverterInputStatus
    init(_ buffer: AVAudioPCMBuffer, then end: AVAudioConverterInputStatus) {
        self.buffer = buffer
        self.end = end
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = end
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
