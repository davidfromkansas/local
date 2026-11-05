import AVFoundation
import Observation
import TakiCore
import TakiEngine
import UIKit

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
    @ObservationIgnored private var silentPlayer: AVAudioPlayerNode?
    @ObservationIgnored private var debugBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var captureStartedAt: Date?
    @ObservationIgnored private var feedSamples: [Float]?
    /// Live transcription of the dictation in progress.
    @ObservationIgnored private var live: LiveTranscriber?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// How many captured samples have been handed to `live`.
    @ObservationIgnored private var liveSampleCount = 0
    @ObservationIgnored private var liveRequestID: UUID?

    /// Pause between live transcription passes (each pass also waits for the previous one).
    static let livePassInterval: Duration = .milliseconds(300)

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
            } catch where Self.debugFeedEnabled {
                // Simulator on a Mac with no audio hardware: run the session on the test feed alone.
                discardAudioEngine()
                beginDebugBackgroundTask()
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
        if machine.phase == .capturing {
            _ = capture.finish()
            stopLiveTranscription()
        }
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
            startLiveTranscription()
        case .stopEngine:
            stopAudio()
        default:
            break
        }
        publish()
    }

    func stopCapture() {
        guard machine.handle(.stopCapture) == .finishCapture else { return }
        let captured = capture.finish()
        let samples = feedSamples ?? captured
        // Only the audio the live transcriber hasn't seen yet.
        let rest = liveSampleCount < samples.count ? Array(samples[liveSampleCount...]) : []
        let transcriber = live ?? LiveTranscriber(engine: engine)
        let lastPass = liveTask
        let requestID = liveRequestID ?? store.readRequest()?.id
        stopLiveTranscription()
        feedSamples = nil
        captureStartedAt = nil
        level = 0
        publish()
        Task {
            await lastPass?.value  // its audio goes in before `rest`
            await transcriber.append(rest)
            await process(transcriber, requestID: requestID, audioSeconds: Double(samples.count) / 16_000)
        }
    }

    func cancelCapture() {
        if machine.handle(.cancelCapture(now: .now)) == .discardCapture {
            _ = capture.finish()
            stopLiveTranscription()
            feedSamples = nil
            captureStartedAt = nil
            level = 0
        }
        publish()
    }

    /// Final pass. The words are already in the text field from the live passes, so this only
    /// transcribes the last moment of audio, applies the instant rules cleanup and hands the text
    /// over right away. The slower Foundation Models polish runs afterwards and, if it changes
    /// anything, sends a revision that the keyboard swaps in.
    private func process(_ transcriber: LiveTranscriber, requestID: UUID?, audioSeconds: Double) async {
        let clock = ContinuousClock()
        do {
            try await engine.prepare(modelChoice())
            let pipeline = makePipeline()
            let asrStart = clock.now
            let raw = try await transcriber.transcribe(final: true)
            let asrTime = asrStart.duration(to: clock.now)

            let quick = pipeline.quickClean(raw)
            lastText = quick
            store.write(DictationResult(requestID: requestID, text: quick))
            DarwinNotifications.post(.resultReady)
            _ = machine.handle(.processingFinished(now: .now))
            publish()

            let polishStart = clock.now
            let polished = await pipeline.polish(quick)
            let polishTime = polishStart.duration(to: clock.now)
            if let polished, polished != quick {
                lastText = polished
                store.write(DictationResult(requestID: requestID, text: polished))
                DarwinNotifications.post(.resultReady)
            }
            let text = polished ?? quick
            guard !text.isEmpty else { return }
            onFinished(DictationOutput(
                rawText: raw, text: text, audioSeconds: audioSeconds,
                asrSeconds: Self.seconds(asrTime), cleanupSeconds: Self.seconds(polishTime),
                usedLanguageModel: polished != nil
            ))
        } catch {
            lastError = error.localizedDescription
            store.write(DictationResult(requestID: requestID, text: ""))
            DarwinNotifications.post(.resultReady)
            _ = machine.handle(.processingFinished(now: .now))
            publish(error: error.localizedDescription)
        }
    }

    private func makePipeline() -> DictationPipeline {
        DictationPipeline(
            engine: engine,
            dictionary: dictionaryProvider(),
            cleanupEnabled: UserDefaults.standard.bool(forKey: SettingsKey.cleanup)
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Live text

    /// While capturing, re-transcribe every few hundred ms and publish the raw words so the keyboard
    /// can type them into the field as the user speaks; the final pass swaps in the cleaned text.
    private func startLiveTranscription() {
        stopLiveTranscription()
        let transcriber = LiveTranscriber(engine: engine)
        let requestID = store.readRequest()?.id
        live = transcriber
        liveRequestID = requestID
        liveSampleCount = 0
        liveTask = Task { [weak self] in
            var published = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.livePassInterval)
                guard let self, !Task.isCancelled else { return }
                let audio = newLiveAudio()
                guard !audio.isEmpty else { continue }
                await transcriber.append(audio)
                guard !Task.isCancelled else { return }
                guard let raw = try? await transcriber.transcribe() else { continue }
                // Stopped or cancelled meanwhile: the final pass owns the text now.
                guard !Task.isCancelled, live === transcriber else { return }
                guard raw != published else { continue }
                published = raw
                store.writePartial(DictationResult(requestID: requestID, text: raw))
                DarwinNotifications.post(.partialReady)
            }
        }
    }

    private func stopLiveTranscription() {
        liveTask?.cancel()
        liveTask = nil
        live = nil
        liveRequestID = nil
    }

    /// Captured audio the live transcriber hasn't seen yet. With the DEBUG feed, the part of the
    /// file that would have been spoken by now.
    private func newLiveAudio() -> [Float] {
        let audio: [Float]
        if let feed = feedSamples, let started = captureStartedAt {
            let end = min(feed.count, Int(Date.now.timeIntervalSince(started) * 16_000))
            audio = liveSampleCount < end ? Array(feed[liveSampleCount..<end]) : []
        } else {
            audio = capture.samples(from: liveSampleCount)
        }
        liveSampleCount += audio.count
        return audio
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
                case .resultReady, .partialReady, .stateChanged: break
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
                capture.publish(feedWindow: Self.feedWindow(feed, at: elapsed))
            }
            level = capture.level
            if elapsed > Self.maxCaptureSeconds { stopCapture() }
        }
        if machine.handle(.tick(now: .now)) == .stopEngine {
            stopAudio()
            publish()
        } else if machine.phase != .inactive, Date.now.timeIntervalSince(lastHeartbeat) >= 2 {
            lastHeartbeat = .now
            store.write(machine.snapshot)
        }
    }

    // MARK: - Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let audioEngine = AVAudioEngine()
        if session.isInputAvailable, case let format = audioEngine.inputNode.outputFormat(forBus: 0),
           format.channelCount > 0, format.sampleRate > 0 {
            capture.install(on: audioEngine.inputNode, format: format)
        } else if Self.debugFeedEnabled {
            // No mic (simulator on a Mac without one): play silence so the engine keeps the app alive.
            try startSilentKeepAlive(on: audioEngine)
        } else {
            throw HotMicError.noMicrophone
        }
        audioEngine.prepare()
        try audioEngine.start()
        silentPlayer?.play()
        self.audioEngine = audioEngine
    }

    private func startSilentKeepAlive(on audioEngine: AVAudioEngine) throws {
        let player = AVAudioPlayerNode()
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        guard mixerFormat.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: mixerFormat.sampleRate, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mixerFormat.sampleRate)) else {
            throw HotMicError.noMicrophone
        }
        silence.frameLength = silence.frameCapacity
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
        player.scheduleBuffer(silence, at: nil, options: .loops)
        silentPlayer = player
    }

    private static var debugFeedEnabled: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: SettingsKey.debugFeed)
        #else
        false
        #endif
    }

    private func discardAudioEngine() {
        silentPlayer?.stop()
        silentPlayer = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    /// DEBUG only: without a running audio engine iOS would suspend us in the background.
    private func beginDebugBackgroundTask() {
        guard debugBackgroundTask == .invalid else { return }
        debugBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TakiDebugFeed") { [weak self] in
            self?.endDebugBackgroundTask()
        }
    }

    private func endDebugBackgroundTask() {
        guard debugBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(debugBackgroundTask)
        debugBackgroundTask = .invalid
    }

    private func stopAudio() {
        ticker?.cancel()
        ticker = nil
        endDebugBackgroundTask()
        if silentPlayer == nil { audioEngine?.inputNode.removeTap(onBus: 0) }
        silentPlayer?.stop()
        silentPlayer = nil
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

    private static func feedWindow(_ samples: [Float], at seconds: Double) -> [Float] {
        let start = Int(seconds * 16_000)
        guard start < samples.count else { return [] }
        return Array(samples[start..<min(samples.count, start + 800)])
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
