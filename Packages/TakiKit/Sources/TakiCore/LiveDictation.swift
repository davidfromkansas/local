import Foundation

/// The fewest keystrokes that turn the text already typed into the field into new text:
/// keep the shared start, delete the rest, type the new ending.
public struct TextEdit: Sendable, Equatable {
    public var deleteCount: Int
    public var insert: String

    public init(deleteCount: Int, insert: String) {
        self.deleteCount = deleteCount
        self.insert = insert
    }

    public static func from(_ old: String, to new: String) -> TextEdit {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return TextEdit(deleteCount: old.count - common, insert: String(new.dropFirst(common)))
    }

    /// True when the text before the cursor still ends with what we typed, so editing it is safe.
    /// iOS can hand a keyboard only part of a long document, so a shorter context counts when it
    /// matches the end of what we typed.
    public static func field(_ context: String, endsWith typed: String) -> Bool {
        if context.hasSuffix(typed) { return true }
        return !context.isEmpty && context.count < typed.count && typed.hasSuffix(context)
    }
}

/// Picks where to cut live audio so older speech can be transcribed once and kept,
/// leaving only the newest stretch (shorter than one 15 s encoder window) to re-transcribe.
public enum SpeechSegmenter {
    public static let sampleRate = 16_000
    /// Start looking for a pause once this much audio is waiting.
    public static let softLimit = 8 * sampleRate
    /// Always cut before this much, so the rest fits one encoder window.
    public static let hardLimit = 14 * sampleRate
    /// Never cut closer to the start than this (very short pieces lose context).
    static let minimumPiece = 4 * sampleRate
    static let frame = sampleRate / 10  // 100 ms
    /// Quieter than this (absolute RMS) counts as a pause.
    public static let pauseRMS: Float = 0.01

    /// Sample index to cut at, or `nil` to keep waiting for more audio.
    /// Cuts in the quietest 100 ms between 4 s and the newest audio: below the soft limit never,
    /// up to the hard limit only at a real pause, past it always.
    public static func cutPoint(in samples: [Float]) -> Int? {
        guard samples.count > softLimit else { return nil }
        // Leave out the newest frame: it may be the start of a word.
        let searchEnd = min(samples.count, hardLimit) - frame
        guard searchEnd - minimumPiece >= frame else { return nil }

        var best: (index: Int, rms: Float)?
        var index = minimumPiece
        while index + frame <= searchEnd {
            let level = rms(samples[index..<(index + frame)])
            // `<=` prefers the latest of equally quiet frames, keeping the re-transcribed tail short.
            if best == nil || level <= best!.rms { best = (index, level) }
            index += frame / 2
        }
        guard let best else { return nil }
        let overall = rms(samples[0..<searchEnd])
        let isPause = best.rms < pauseRMS || best.rms < overall * 0.15
        guard isPause || samples.count >= hardLimit else { return nil }
        return best.index + frame / 2
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
