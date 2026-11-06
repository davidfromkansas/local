@preconcurrency import CoreML
import FluidAudio
import Foundation
import TakiCore

/// Speech-to-text model the user can choose in Settings.
public enum ASRModelChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Parakeet Unified 0.6B English, batch (full-attention 15 s encoder), fp16 encoder.
    case parakeetUnified
    /// Parakeet TDT 0.6B v2 English — fallback option.
    case parakeetTDTv2

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeetUnified: "Parakeet Unified (recommended)"
        case .parakeetTDTv2: "Parakeet TDT v2"
        }
    }

    public var approximateDownload: String {
        switch self {
        case .parakeetUnified: "about 1.2 GB"
        case .parakeetTDTv2: "about 500 MB"
        }
    }
}

public enum TranscriptionError: LocalizedError, Sendable {
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .notPrepared: "Speech model isn't loaded yet."
        }
    }
}

/// Owns the Core ML models (ASR + Silero VAD). Lives in the main app only.
public actor TranscriptionEngine {
    /// `<Application Support>/Taki` — FluidAudio stores bundles under `Models/<repo>`.
    public let baseDirectory: URL
    public private(set) var loadedChoice: ASRModelChoice?

    private var unified: UnifiedAsrManager?
    private var tdt: AsrManager?
    private var vad: VadManager?
    /// The load in flight, shared by concurrent `prepare` calls (app launch, session start, dictation)
    /// so a second caller can't `unload()` the models the first one is still loading.
    private var loading: (choice: ASRModelChoice, task: Task<Void, Error>)?

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? URL.applicationSupportDirectory.appending(path: "Taki", directoryHint: .isDirectory)
    }

    public var modelsDirectory: URL { baseDirectory.appending(path: "Models", directoryHint: .isDirectory) }

    private func repoDirectory(for choice: ASRModelChoice) -> URL {
        switch choice {
        case .parakeetUnified: modelsDirectory.appending(path: Repo.parakeetUnified.folderName)
        case .parakeetTDTv2: modelsDirectory.appending(path: Repo.parakeetV2.folderName)
        }
    }

    /// True once the model files are on disk (no network needed to load them).
    public func isDownloaded(_ choice: ASRModelChoice) -> Bool {
        let dir = repoDirectory(for: choice)
        let required: [String] = switch choice {
        case .parakeetUnified:
            [UnifiedModelFamily.parakeetEnglish.offlineEncoderFile(precision: .fp16),
             UnifiedModelFamily.parakeetEnglish.decoderFile]
        case .parakeetTDTv2:
            ["Decoder.mlmodelc", "JointDecision.mlmodelc"]
        }
        return required.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
    }

    /// Neural Engine + CPU only: GPU work is not allowed while the app is in the background.
    private static func modelConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return configuration
    }

    /// Downloads (first time only), compiles and loads the chosen model plus VAD. `progress` is 0…1.
    public func prepare(_ choice: ASRModelChoice, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if loadedChoice == choice, vad != nil { return }
        if let loading, loading.choice == choice { return try await loading.task.value }
        let task = Task { try await self.load(choice, progress: progress) }
        loading = (choice, task)
        defer { if loading?.task == task { loading = nil } }
        try await task.value
    }

    private func load(_ choice: ASRModelChoice, progress: (@Sendable (Double) -> Void)?) async throws {
        unload()
        let handler: ProgressHandler = { update in progress?(update.fractionCompleted * 0.95) }

        switch choice {
        case .parakeetUnified:
            // fp16 encoder: the int8 one fails to load on A-series chips (FluidAudio issue #828).
            let manager = UnifiedAsrManager(configuration: Self.modelConfiguration(), encoderPrecision: .fp16)
            try await manager.loadModels(to: modelsDirectory, progressHandler: handler)
            unified = manager
        case .parakeetTDTv2:
            let models = try await AsrModels.downloadAndLoad(
                to: repoDirectory(for: .parakeetTDTv2),
                configuration: Self.modelConfiguration(),
                version: .v2,
                progressHandler: handler
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            tdt = manager
        }

        var vadConfig = VadConfig.default
        vadConfig.computeUnits = .cpuAndNeuralEngine
        vad = try await VadManager(config: vadConfig, modelDirectory: baseDirectory)
        loadedChoice = choice

        // Warm-up pass so the first real dictation doesn't pay Core ML's first-run cost.
        _ = try? await transcribeRaw([Float](repeating: 0, count: 16_000))
        progress?(1)
    }

    public func unload() {
        unified = nil
        tdt = nil
        vad = nil
        loadedChoice = nil
    }

    /// 16 kHz mono Float32 in, raw ASR text out. Leading/trailing silence is trimmed with Silero VAD.
    public func transcribe(_ samples: [Float]) async throws -> String {
        let trimmed = try await trimSilence(samples)
        guard trimmed.count >= 4_000 else { return "" }  // < 0.25 s of speech
        return try await transcribeRaw(trimmed)
    }

    private func transcribeRaw(_ samples: [Float]) async throws -> String {
        // Pad short clips to 1 s; both encoders expect at least that much context.
        var input = samples
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        if let unified {
            return try await unified.transcribe(input).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let tdt {
            var state = TdtDecoderState.make()
            return try await tdt.transcribe(input, decoderState: &state).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw TranscriptionError.notPrepared
    }

    private func trimSilence(_ samples: [Float]) async throws -> [Float] {
        guard let vad, samples.count > 16_000 else { return samples }
        var config = VadSegmentationConfig.default
        config.speechPadding = 0.25
        config.minSpeechDuration = 0.15
        let segments = try await vad.segmentSpeech(samples, config: config)
        guard let first = segments.first, let last = segments.last else {
            // VAD heard nothing: keep the audio only if it isn't near-silent.
            return AudioLevel.rms(samples) > 0.01 ? samples : []
        }
        let start = max(0, first.startSample(sampleRate: 16_000))
        let end = min(samples.count, last.endSample(sampleRate: 16_000))
        return start < end ? Array(samples[start..<end]) : samples
    }
}

public enum AudioLevel {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS → 0…1 on a -50 dB…0 dB scale.
    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, 1 - abs(db / 50)))
    }
}
