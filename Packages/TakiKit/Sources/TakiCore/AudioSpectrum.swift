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

    public func bands() -> [Float] {
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
            let db = 20 * log10(peak / fullScale) + 14 * Float(band) / Float(Self.bandCount)
            return min(1, max(0, (db + 62) / 50))
        }
    }
}
