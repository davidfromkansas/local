import AVFoundation
#if DEBUG
import os
#endif
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
    private let analyzer = SpectrumAnalyzer()
    private var gain = AutoGain()
    private var gainDB: Float = 0
    #if DEBUG
    private let logger = Logger(subsystem: "com.davidfromkansas.taki", category: "audio")
    private var lastDebugLog: CFAbsoluteTime = 0
    #endif
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
            analyzer.reset()
            gain.reset()
            gainDB = 0
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
        store.writeSpectrum([])
        return captured
    }

    var capturedSeconds: Double { lock.withLock { Double(samples.count) / 16_000 } }

    /// Copy of what's been captured from `index` on, for live transcription while still capturing.
    func samples(from index: Int) -> [Float] {
        lock.withLock { index < samples.count ? Array(samples[index...]) : [] }
    }

    /// Used by the DEBUG file feed so the keyboard visuals still move: `window` is the audio "playing" now.
    func publish(feedWindow window: [Float]) {
        let level = AudioLevel.normalized(rms: AudioLevel.rms(window))
        let bands = lock.withLock {
            currentLevel = level
            analyzer.append(window)
            return analyzer.bands()
        }
        store.writeLevel(level)
        store.writeSpectrum(bands)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ isCapturing }), let converted = convert(buffer) else { return }
        let rms = AudioLevel.rms(converted)
        let (level, boost) = lock.withLock {
            gainDB = gain.update(rms: rms, seconds: Float(converted.count) / 16_000)
            return (AudioLevel.normalized(rms: rms, gainDB: gainDB), gainDB)
        }
        lock.withLock {
            guard isCapturing else { return }
            samples.append(contentsOf: converted)
            currentLevel = level
            analyzer.append(converted)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelWrite > 1.0 / 30 {
            lastLevelWrite = now
            store.writeLevel(level)
            store.writeSpectrum(lock.withLock { analyzer.bands(gainDB: boost) })
        }
        #if DEBUG
        if now - lastDebugLog > 0.5 {
            lastDebugLog = now
            let db = rms > 0 ? 20 * log10(rms) : -160
            logger.notice("TAKIAUDIO rms \(db, format: .fixed(precision: 1), privacy: .public) dB gain \(boost, format: .fixed(precision: 1), privacy: .public) dB level \(level, format: .fixed(precision: 2), privacy: .public)")
        }
        #endif
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
