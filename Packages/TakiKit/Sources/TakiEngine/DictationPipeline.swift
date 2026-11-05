import Foundation
import TakiCore

public struct DictationOutput: Sendable {
    public var rawText: String
    public var text: String
    public var audioSeconds: Double
    public var asrSeconds: Double
    public var cleanupSeconds: Double
    public var usedLanguageModel: Bool

    public init(
        rawText: String, text: String, audioSeconds: Double, asrSeconds: Double, cleanupSeconds: Double,
        usedLanguageModel: Bool
    ) {
        self.rawText = rawText
        self.text = text
        self.audioSeconds = audioSeconds
        self.asrSeconds = asrSeconds
        self.cleanupSeconds = cleanupSeconds
        self.usedLanguageModel = usedLanguageModel
    }
}

/// samples → VAD trim → ASR → rules cleanup → (optional) Foundation Models polish → guard.
///
/// Live dictation uses the two cleanup steps on their own: `quickClean` is instant (live text and the
/// first final text), `polish` is slower and replaces the text afterwards when it helps.
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
        var text = quickClean(raw)
        var usedLLM = false
        if let polished = await polish(text) {
            text = polished
            usedLLM = true
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

    /// Rules cleanup (fillers, stutters, self-corrections, dictionary, punctuation). Instant.
    public func quickClean(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        if cleanupEnabled { return TextCleaner(dictionary: dictionary).clean(raw) }
        return dictionary.isEmpty ? raw : TextCleaner.applyDictionary(dictionary, to: raw)
    }

    /// Foundation Models light edit of `quickClean` output; `nil` when off, unavailable or rejected.
    public func polish(_ cleaned: String) async -> String? {
        guard cleanupEnabled, !cleaned.isEmpty, let polished = await LLMCleaner().polish(cleaned) else { return nil }
        // Re-apply the dictionary so the model can't undo personal spellings.
        return TextCleaner.applyDictionary(dictionary, to: polished)
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
