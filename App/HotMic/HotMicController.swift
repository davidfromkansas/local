import AVFoundation
import Observation
import TakiCore
import TakiEngine

/// The "hot mic": keeps an AVAudioEngine running (armed) so the app stays alive in the
/// background, and flips to capturing when the keyboard asks over Darwin notifications.
@Observable
final class HotMicController {
    private(set) var machine = SessionMachine()
    private(set) var level: Float = 0
    private(set) var lastError: String?
    private(set) var lastText: String?

    @ObservationIgnored var modelChoice: () -> ASRModelChoice = { .parakeetUnified }
    @ObservationIgnored var dictionaryProvider: () -> [DictionaryEntry] = { [] }
    @ObservationIgnored var onFinished: (DictationOutput) -> Void = { _ in }

    @ObservationIgnored private let engine: TranscriptionEngine
    @ObservationIgnored private let store: SharedStore
    @ObservationIgnored private let capture: CaptureContext
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var captureStartedAt: Date?
    @ObservationIgnored private var feedSamples: [Float]?

    /// Longest single dictation we accumulate before stopping automatically.
    static let maxCaptureSeconds: Double = 5 * 60

    var phase: SessionPhase { machine.phase }
    var expiresAt: Date? { machine.expiresAt }

    init(engine: TranscriptionEngine) {
        self.engine = engine
        store = SharedStore() ?? SharedStore(directory: URL.temporaryDirectory.appending(path: "TakiShared"))
        capture = CaptureContext(store: store)
        store.write(SessionSnapshot.inactive)
        listen()
    }

    // MARK: - Session

    func activate() {
        lastError = nil
        machine.idleTimeout = UserDefaults.standard.double(forKey: SettingsKey.timeout)
        if machine.handle(.activate(now: .now)) == .startEngine {
            do {
                try startAudio()
            } catch {
                lastError = "Couldn't start the microphone: \(error.localizedDescription)"
                _ = machine.handle(.end)
                publish()
                return
            }
            startTicker()
        }
        publish()
        let choice = modelChoice()
        Task { try? await engine.prepare(choice) }
    }

    func endSession() {
        if machine.phase == .capturing { _ = capture.finish() }
        _ = machine.handle(.end)
        stopAudio()
        publish()
    }

    func toggleCapture() {
        switch machine.phase {
        case .armed: startCapture()
        case .capturing: stopCapture()
        case .inactive, .processing: break
        }
    }

    func startCapture() {
        switch machine.handle(.startCapture(now: .now)) {
        case .beginCapture:
            captureStartedAt = .now
            feedSamples = loadDebugFeedIfEnabled()
            capture.begin()
        case .stopEngine:
            stopAudio()
        default:
            break
        }
        publish()
    }

    func stopCapture() {
        guard machine.handle(.stopCapture) == .finishCapture else { return }
        var samples = capture.finish()
        if let feed = feedSamples {
            samples = feed
            feedSamples = nil
        }
        captureStartedAt = nil
        level = 0
        publish()
        Task { await process(samples) }
    }

    func cancelCapture() {
        if machine.handle(.cancelCapture(now: .now)) == .discardCapture {
            _ = capture.finish()
            feedSamples = nil
            captureStartedAt = nil
            level = 0
        }
        publish()
    }

    private func process(_ samples: [Float]) async {
        let requestID = store.readRequest()?.id
        var errorMessage: String?
        do {
            try await engine.prepare(modelChoice())
            let pipeline = DictationPipeline(
                engine: engine,
                dictionary: dictionaryProvider(),
                cleanupEnabled: UserDefaults.standard.bool(forKey: SettingsKey.cleanup)
            )
            let output = try await pipeline.run(samples)
            lastText = output.text
            store.write(DictationResult(requestID: requestID, text: output.text))
            if !output.text.isEmpty { onFinished(output) }
        } catch {
            errorMessage = error.localizedDescription
            lastError = errorMessage
            store.write(DictationResult(requestID: requestID, text: ""))
        }
        DarwinNotifications.post(.resultReady)
        _ = machine.handle(.processingFinished(now: .now))
        publish(error: errorMessage)
    }

    // MARK: - IPC

    private func publish(error: String? = nil) {
        var snapshot = machine.snapshot
        snapshot.errorMessage = error
        store.write(snapshot)
        DarwinNotifications.post(.stateChanged)
    }

    private func listen() {
        listener = Task { [weak self] in
            for await signal in DarwinNotifications.signals([.start, .stop, .cancel]) {
                guard let self else { return }
                switch signal {
                case .start: startCapture()
                case .stop: stopCapture()
                case .cancel: cancelCapture()
                case .resultReady, .stateChanged: break
                }
            }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.tick()
            }
        }
    }

    private func tick() {
        if machine.phase == .capturing, let started = captureStartedAt {
            let elapsed = Date.now.timeIntervalSince(started)
            if let feed = feedSamples {
                capture.publish(level: Self.feedLevel(feed, at: elapsed))
            }
            level = capture.level
            if elapsed > Self.maxCaptureSeconds { stopCapture() }
        }
        if machine.handle(.tick(now: .now)) == .stopEngine {
            stopAudio()
            publish()
        }
    }

    // MARK: - Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw HotMicError.noMicrophone
        }
        capture.install(on: input, format: format)
        audioEngine.prepare()
        try audioEngine.start()
        self.audioEngine = audioEngine
    }

    private func stopAudio() {
        ticker?.cancel()
        ticker = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - DEBUG file feed (the cloud Mac / simulator has no microphone)

    private func loadDebugFeedIfEnabled() -> [Float]? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: SettingsKey.debugFeed) else { return nil }
        let candidates = [store.debugFeedURL, Bundle.main.url(forResource: "debug-feed", withExtension: "wav")]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path()) {
            if let samples = try? AudioFile.load16kMono(url) { return samples }
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func feedLevel(_ samples: [Float], at seconds: Double) -> Float {
        let start = Int(seconds * 16_000)
        guard start < samples.count else { return 0 }
        let window = samples[start..<min(samples.count, start + 800)]
        return AudioLevel.normalized(rms: AudioLevel.rms(Array(window)))
    }
}

enum HotMicError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: "No microphone is available."
        }
    }
}
