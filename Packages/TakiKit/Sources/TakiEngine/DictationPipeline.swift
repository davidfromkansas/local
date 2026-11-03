import Foundation
import TakiCore

public struct DictationOutput: Sendable {
    public var rawText: String
    public var text: String
    public var audioSeconds: Double
    public var asrSeconds: Double
    public var cleanupSeconds: Double
    public var usedLanguageModel: Bool
}

/// samples → VAD trim → ASR → rules cleanup → (optional) Foundation Models polish → guard.
public struct DictationPipeline: Sendable {
    public let engine: TranscriptionEngine
    public var dictionary: [DictionaryEntry]
    public var cleanupEnabled: Bool

    public init(engine: TranscriptionEngine, dictionary: [DictionaryEntry] = [], cleanupEnabled: Bool = true) {
        self.engine = engine
        self.dictionary = dictionary
        self.cleanupEnabled = cleanupEnabled
    }

    public func run(_ samples: [Float]) async throws -> DictationOutput {
        let clock = ContinuousClock()
        let asrStart = clock.now
        let raw = try await engine.transcribe(samples)
        let asrDuration = asrStart.duration(to: clock.now)

        let cleanupStart = clock.now
        var text = raw
        var usedLLM = false
        if cleanupEnabled, !raw.isEmpty {
            let rules = TextCleaner(dictionary: dictionary).clean(raw)
            text = rules
            if let polished = await LLMCleaner().polish(rules) {
                // Re-apply the dictionary so the model can't undo personal spellings.
                text = TextCleaner.applyDictionary(dictionary, to: polished)
                usedLLM = true
            }
        } else if !dictionary.isEmpty {
            text = TextCleaner.applyDictionary(dictionary, to: raw)
        }
        let cleanupDuration = cleanupStart.duration(to: clock.now)

        return DictationOutput(
            rawText: raw,
            text: text,
            audioSeconds: Double(samples.count) / 16_000,
            asrSeconds: asrDuration.seconds,
            cleanupSeconds: cleanupDuration.seconds,
            usedLanguageModel: usedLLM
        )
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
