import Accelerate

/// Log-spaced frequency bands (0…1) of the most recent audio, the input to Taki's voice orb.
/// Same recipe as 2D spectrum visualizers: Hann window → FFT → magnitude in dB → log-frequency bands.
/// Not thread-safe; the owner serializes access.
public final class SpectrumAnalyzer {
    public static let bandCount = 24
    public static let windowSize = 512

    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zeros = [Float](repeating: 0, count: SpectrumAnalyzer.windowSize)
    /// FFT bin index where each band starts; `bandCount + 1` strictly increasing edges.
    private let edges: [Int]
    private var tail: [Float] = []

    public init(sampleRate: Float = 16_000) {
        let n = Self.windowSize
        dft = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let low: Float = 90, high: Float = 7_600, binHz = sampleRate / Float(n)
        var edges = (0...Self.bandCount).map { i in
            Int((low * pow(high / low, Float(i) / Float(Self.bandCount)) / binHz).rounded())
        }
        for i in edges.indices {
            edges[i] = min(n / 2, max(edges[i], i == 0 ? 1 : edges[i - 1] + 1))
        }
        self.edges = edges
    }

    public func append(_ samples: [Float]) {
        tail.append(contentsOf: samples.suffix(Self.windowSize))
        if tail.count > Self.windowSize { tail.removeFirst(tail.count - Self.windowSize) }
    }

    public func reset() { tail.removeAll(keepingCapacity: true) }

    /// `gainDB` lifts quiet input (see `AutoGain`) before mapping to 0…1.
    public func bands(gainDB: Float = 0) -> [Float] {
        guard tail.count == Self.windowSize else { return [Float](repeating: 0, count: Self.bandCount) }
        let (real, imaginary) = dft.transform(real: vDSP.multiply(tail, window), imaginary: zeros)
        // A full-scale sine peaks at N/4 with a Hann window.
        let fullScale = Float(Self.windowSize) / 4
        return (0..<Self.bandCount).map { band in
            var peak: Float = 0
            for bin in edges[band]..<max(edges[band] + 1, edges[band + 1]) {
                peak = max(peak, (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot())
            }
            guard peak > 0 else { return 0 }
            // Speech energy falls off with frequency; tilt up the highs so the whole range moves.
            let db = 20 * log10(peak / fullScale) + 14 * Float(band) / Float(Self.bandCount) + gainDB
            return min(1, max(0, (db + 62) / 50))
        }
    }
}

/// Mic loudness → 0…1 for the visuals, measured against the room: the recent noise floor is 0 and the loudest
/// recent sound is 1. A raw iPhone mic (`.measurement` mode) puts quiet speech near -46 dBFS and whispers near
/// -60, which any fixed dB scale reads as silence.
public struct VoiceMeter {
    /// How fast the noise floor creeps up while it's louder than the floor, in dB per second.
    public static let noiseRise: Float = 3
    /// How fast the remembered peak falls, in dB per second.
    public static let peakRelease: Float = 6
    /// Sound this many dB over the floor still counts as silence (noise jitter).
    public static let gate: Float = 4
    /// Smallest dB range mapped to 0…1, so a whisper doesn't have to be loud to fill it.
    public static let minSpan: Float = 12
    /// The floor never sits below this, so a silent first buffer can't make room noise look loud.
    public static let lowestFloor: Float = -75
    public static let maxSpectrumGain: Float = 36

    private var floor: Float?
    private var peak = VoiceMeter.lowestFloor

    public init() {}

    public mutating func reset() {
        floor = nil
        peak = Self.lowestFloor
    }

    /// Feeds one buffer's RMS, `seconds` long. Returns its 0…1 level and the dB gain to apply to its spectrum.
    public mutating func update(rms: Float, seconds: Float) -> (level: Float, gainDB: Float) {
        guard rms > 0 else { return (0, 0) }
        let db = 20 * log10(rms)
        let noise = max(Self.lowestFloor, min(db, (floor ?? db) + Self.noiseRise * seconds))
        floor = noise
        peak = max(db, peak - Self.peakRelease * seconds)
        let span = max(Self.minSpan, peak - noise - Self.gate)
        let level = min(1, max(0, (db - noise - Self.gate) / span))
        let gain = min(Self.maxSpectrumGain, max(0, -20 - peak))
        return (level, gain)
    }
}

/// Turns quiet recordings up before the speech detector and the speech model see them.
public enum SpeechLoudness {
    /// Speech is lifted to about this RMS level (normal talking volume).
    public static let targetDB: Float = -20
    public static let maxGainDB: Float = 30
    private static let window = 1_600  // 100 ms at 16 kHz

    /// RMS of the loudest-but-one-in-ten 100 ms window: the level of the speech itself, not the pauses.
    public static func speechRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var levels: [Float] = stride(from: 0, to: samples.count, by: window).map { start in
            let chunk = samples[start..<min(samples.count, start + window)]
            return (chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
        }
        levels.sort()
        return levels[min(levels.count - 1, Int(Float(levels.count) * 0.9))]
    }

    public static func boost(_ samples: [Float]) -> [Float] {
        let rms = speechRMS(samples)
        guard rms > 0 else { return samples }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let wanted = pow(10, min(maxGainDB, max(0, targetDB - 20 * log10(rms))) / 20)
        let gain = min(wanted, 0.98 / max(peak, 1e-9))
        return gain > 1.01 ? samples.map { $0 * gain } : samples
    }
}
