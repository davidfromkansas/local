import Foundation

/// Gets a finished recording ready for the speech model: cuts the silence before and after the
/// speech and turns quiet speech (whispers, a far-away mic) up to a normal level.
public enum SpeechGain {
    static let frame = 320  // 20 ms at 16 kHz
    /// Speech level the model hears best, about -20 dBFS.
    static let targetRMS: Float = 0.1
    static let maxGain: Float = 40
    /// A recording whose loudest moment is under about -70 dBFS has no speech in it.
    static let minPeakRMS: Float = 0.0003
    static let padding = 0.3

    /// 16 kHz mono in, trimmed and levelled 16 kHz mono out. Empty when nothing sounds like speech.
    public static func prepare(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let frames = samples.count / frame
        guard frames > 0 else { return [] }
        let levels = (0..<frames).map { i in rms(samples[(i * frame)..<((i + 1) * frame)]) }
        let loudest = levels.max() ?? 0
        guard loudest >= minPeakRMS else { return [] }
        // Speech = clearly above the room's noise floor; relative, so very quiet recordings keep their words.
        let floor = levels.sorted()[frames / 10]
        let threshold = min(max(floor * 3, loudest * 0.05), loudest * 0.5)
        let voiced = levels.indices.filter { levels[$0] >= threshold }
        guard let first = voiced.first, let last = voiced.last else { return [] }

        let pad = Int(padding * Double(sampleRate))
        let start = max(0, first * frame - pad), end = min(samples.count, (last + 1) * frame + pad)
        let speechRMS = sqrt(voiced.map { levels[$0] * levels[$0] }.reduce(0, +) / Float(voiced.count))
        let peak = samples[start..<end].reduce(Float(0)) { max($0, abs($1)) }
        let gain = max(1, min(maxGain, targetRMS / max(speechRMS, 1e-6), 0.95 / max(peak, 1e-6)))
        return samples[start..<end].map { $0 * gain }
    }

    static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
    }
}
