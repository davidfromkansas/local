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
    private var loading: (choice: ASRModelChoice, task: Task<Void, Error>, progress: PrepareProgressFanout)?
    /// Bumped by every new load, so a superseded (restarted) load can't install its models.
    private var generation = 0

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

    /// Downloads (first time only), compiles and loads the chosen model plus VAD.
    /// `restart` abandons a load in flight (e.g. one that seems stuck) and starts over.
    public func prepare(
        _ choice: ASRModelChoice,
        restart: Bool = false,
        progress: (@Sendable (PrepareProgress) -> Void)? = nil
    ) async throws {
        if !restart, loadedChoice == choice, vad != nil { return }
        if !restart, let loading, loading.choice == choice {
            if let progress { loading.progress.add(progress) }
            return try await loading.task.value
        }
        loading?.task.cancel()
        generation += 1
        let fanout = PrepareProgressFanout()
        if let progress { fanout.add(progress) }
        let task = Task { [generation] in try await self.load(choice, generation: generation, progress: fanout) }
        loading = (choice, task, fanout)
        defer { if loading?.task == task { loading = nil } }
        try await task.value
    }

    private func load(_ choice: ASRModelChoice, generation: Int, progress: PrepareProgressFanout) async throws {
        unload()
        func current() throws {
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
        }
        let handler: ProgressHandler = { update in
            switch update.phase {
            case .listing, .downloading:
                // FluidAudio gives the download the first half of its range and compiling the rest.
                progress.send(PrepareProgress(stage: .downloading, fraction: min(update.fractionCompleted / 0.5, 1)))
            case let .compiling(modelName):
                progress.send(PrepareProgress(stage: .loadingModel, fraction: update.fractionCompleted, detail: modelName))
            }
        }

        switch choice {
        case .parakeetUnified:
            // fp16 encoder: the int8 one fails to load on A-series chips (FluidAudio issue #828).
            let manager = UnifiedAsrManager(configuration: Self.modelConfiguration(), encoderPrecision: .fp16)
            try await manager.loadModels(to: modelsDirectory, progressHandler: handler)
            try current()
            unified = manager
        case .parakeetTDTv2:
            let models = try await AsrModels.downloadAndLoad(
                to: repoDirectory(for: .parakeetTDTv2),
                configuration: Self.modelConfiguration(),
                version: .v2,
                progressHandler: handler
            )
            try current()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            try current()
            tdt = manager
        }

        progress.send(PrepareProgress(stage: .loadingVAD, fraction: 1))
        var vadConfig = VadConfig.default
        vadConfig.computeUnits = .cpuAndNeuralEngine
        vadConfig.defaultThreshold = Self.vadThreshold
        let vad = try await VadManager(config: vadConfig, modelDirectory: baseDirectory)
        try current()
        self.vad = vad
        loadedChoice = choice

        // Warm-up pass so the first real dictation doesn't pay Core ML's first-run cost.
        progress.send(PrepareProgress(stage: .warmingUp, fraction: 1))
        _ = try? await transcribeRaw([Float](repeating: 0, count: 16_000))
    }

    public func unload() {
        unified = nil
        tdt = nil
        vad = nil
        loadedChoice = nil
    }

    /// Silero's usual 0.5 instead of FluidAudio's 0.85, which drops whispers.
    static let vadThreshold: Float = 0.5
    /// When the VAD hears no speech, still transcribe if the speech-level RMS is above this (-55 dB).
    static let keepWithoutSpeechRMS: Float = 0.0018

    /// 16 kHz mono Float32 in, raw ASR text out. Quiet audio is turned up, then leading/trailing silence is
    /// trimmed with Silero VAD.
    public func transcribe(_ samples: [Float]) async throws -> String {
        let trimmed = try await trimSilence(SpeechLoudness.boost(samples))
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
        config.speechPadding = 0.35
        config.minSpeechDuration = 0.1
        let segments = try await vad.segmentSpeech(samples, config: config)
        guard let first = segments.first, let last = segments.last else {
            // VAD heard nothing: keep the audio only if it isn't near-silent.
            return SpeechLoudness.speechRMS(samples) > Self.keepWithoutSpeechRMS ? samples : []
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

    /// RMS (plus `gainDB`) → 0…1 on a -50 dB…0 dB scale.
    public static func normalized(rms: Float, gainDB: Float = 0) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms) + gainDB
        return min(1, max(0, 1 - abs(db / 50)))
    }
}

/// Where `TranscriptionEngine.prepare` is, so the UI can say what it's doing instead of one long spinner.
public struct PrepareProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Fetching model files (first time only, or when the copy on disk is incomplete).
        case downloading
        /// Compiling / loading the Core ML models. Slow the first time on a device.
        case loadingModel
        case loadingVAD
        case warmingUp
    }

    public var stage: Stage
    /// 0…1 within `stage`.
    public var fraction: Double
    public var detail: String = ""

    public init(stage: Stage, fraction: Double, detail: String = "") {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

/// Fans one load's progress out to every caller waiting on it; late joiners get the latest value.
final class PrepareProgressFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [@Sendable (PrepareProgress) -> Void] = []
    private var latest: PrepareProgress?

    func add(_ observer: @escaping @Sendable (PrepareProgress) -> Void) {
        let latest = lock.withLock {
            observers.append(observer)
            return self.latest
        }
        if let latest { observer(latest) }
    }

    func send(_ progress: PrepareProgress) {
        let observers = lock.withLock {
            latest = progress
            return self.observers
        }
        for observer in observers { observer(progress) }
    }
}
