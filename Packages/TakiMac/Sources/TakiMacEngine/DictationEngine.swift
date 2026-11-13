import Foundation
import TakiCore

public struct MacDictation: Sendable {
    public var rawText: String
    public var text: String
    public var audioSeconds: Double
    public var asrSeconds: Double
    public var cleanupSeconds: Double
    public var usedLanguageModel: Bool
}

/// recording → trim + lift quiet speech → Qwen3-ASR → rules cleanup → LLM polish (guarded) → dictionary.
public struct DictationEngine: Sendable {
    public let speech: SpeechTranscriber
    public let polisher: LLMPolisher

    public init(store: ModelStore = ModelStore()) {
        speech = SpeechTranscriber(store: store)
        polisher = LLMPolisher(store: store)
    }

    public func run(_ samples: [Float], dictionary: [DictionaryEntry] = [], cleanup: Bool = true) async throws -> MacDictation {
        let clock = ContinuousClock()
        let start = clock.now
        let prepared = SpeechGain.prepare(samples)
        let raw = try await speech.transcribe(prepared, vocabulary: dictionary.map(\.output))
        let asrDone = clock.now
        var text = cleanup ? TextCleaner(dictionary: dictionary).clean(raw) : TextCleaner.applyDictionary(dictionary, to: raw)
        var usedLLM = false
        if cleanup, let polished = await polisher.polish(text) {
            text = TextCleaner.applyDictionary(dictionary, to: polished)
            usedLLM = true
        }
        return MacDictation(
            rawText: raw, text: text, audioSeconds: Double(samples.count) / 16_000,
            asrSeconds: (asrDone - start).seconds, cleanupSeconds: (clock.now - asrDone).seconds,
            usedLanguageModel: usedLLM)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
