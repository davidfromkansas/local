import AudioCommon
import Foundation
import Qwen3ASR
import TakiCore

/// Qwen3-ASR on the GPU via MLX. One model, run once on the whole recording.
public actor SpeechTranscriber {
    public let store: ModelStore
    public private(set) var isLoaded = false
    private var model: Qwen3ASRModel?

    public init(store: ModelStore = ModelStore()) {
        self.store = store
    }

    /// Downloads (first time only) and loads the model. `progress` gets 0…1 and a short status.
    public func prepare(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws {
        if model != nil { return }
        let directory = store.speechDirectory
        if !store.isSpeechModelDownloaded {
            try await HuggingFaceDownloader.downloadWeights(
                modelId: SpeechModel.repo, to: directory,
                additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
                progressHandler: { progress($0 * 0.95, "Downloading speech model") })
        }
        progress(0.96, "Loading speech model")
        let model = try await Qwen3ASRModel.fromPretrained(modelId: SpeechModel.repo, cacheDir: directory, offlineMode: true)
        // First run compiles GPU kernels; do it now instead of on the first dictation.
        _ = model.transcribe(audio: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, options: options(context: nil))
        self.model = model
        isLoaded = true
        progress(1, "Ready")
    }

    public func unload() {
        model = nil
        isLoaded = false
    }

    /// 16 kHz mono in, raw words out. `vocabulary` (dictionary terms) nudges spelling of names.
    public func transcribe(_ samples: [Float], vocabulary: [String] = []) throws -> String {
        guard let model else { throw EngineError.notPrepared }
        guard !samples.isEmpty else { return "" }
        var input = samples
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        let context = vocabulary.isEmpty ? nil : "Vocabulary: " + vocabulary.joined(separator: ", ")
        return try model.transcribeCheckingCancellation(audio: input, sampleRate: 16_000, options: options(context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func options(context: String?) -> Qwen3DecodingOptions {
        var options = Qwen3DecodingOptions()
        options.language = "English"
        options.context = context
        return options
    }
}

public enum EngineError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .notPrepared: "The models aren't loaded yet."
        }
    }
}
