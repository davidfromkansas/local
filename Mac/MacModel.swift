import AppKit
import AVFoundation
import TakiCore
import TakiMacEngine

/// The Mac app's brain: hold the hotkey → record → release → one speech model → LLM cleanup → paste.
@Observable
final class MacModel {
    enum Phase: Equatable {
        case needsModels
        case loading(String, Double)
        case ready
        case listening
        case processing
        case failed(String)
    }

    struct HistoryItem: Codable, Identifiable, Hashable {
        var id = UUID()
        var date = Date.now
        var text: String
        var rawText: String
        var audioSeconds: Double
        /// Key release → text pasted.
        var waitSeconds: Double
    }

    private(set) var phase: Phase = .needsModels
    private(set) var history: [HistoryItem] = []
    var dictionary: [DictionaryEntry] = [] { didSet { save(dictionary, to: "dictionary.json") } }
    private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private(set) var micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    private(set) var systemUsesFnKey = Hotkey.systemUsesFnKey

    var cleanupModel: CleanupModelChoice {
        didSet { defaults.set(cleanupModel.rawValue, forKey: "cleanupModel"); if oldValue != cleanupModel { Task { await load() } } }
    }
    var cleanupEnabled: Bool { didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    var hotkey: Hotkey { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey"); hotkeyMonitor.hotkey = hotkey } }

    let store = ModelStore()
    let voice = VoiceLevels()
    @ObservationIgnored private let engine: DictationEngine
    @ObservationIgnored private let capture = MicCapture()
    @ObservationIgnored private let hotkeyMonitor = HotkeyMonitor()
    @ObservationIgnored private lazy var overlay = OrbOverlay(voice: voice)
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?

    init() {
        engine = DictationEngine(store: store)
        cleanupModel = CleanupModelChoice(rawValue: defaults.string(forKey: "cleanupModel") ?? "") ?? .qwen3_4B
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        hotkey = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        history = load([HistoryItem].self, from: "history.json") ?? []
        dictionary = load([DictionaryEntry].self, from: "dictionary.json") ?? []
        if let path = ProcessInfo.processInfo.environment["TAKI_TEST_AUDIO"] {
            capture.testAudio = try? AudioLoader.load16kMono(URL(filePath: path))
        }
    }

    var needsSetup: Bool { !modelsDownloaded || !accessibilityTrusted }

    var modelsDownloaded: Bool {
        store.isSpeechModelDownloaded && (!cleanupEnabled || store.isDownloaded(cleanupModel))
    }

    var menuSymbol: String {
        switch phase {
        case .listening: "waveform.circle.fill"
        case .processing: "ellipsis.circle"
        case .failed: "exclamationmark.circle"
        default: "waveform"
        }
    }

    var lastWait: Double? { history.first?.waitSeconds }

    func start() {
        hotkeyMonitor.hotkey = hotkey
        hotkeyMonitor.onPress = { [weak self] in self?.begin() }
        hotkeyMonitor.onRelease = { [weak self] in self?.finish() }
        hotkeyMonitor.onInterrupt = { [weak self] in self?.cancel() }
        hotkeyMonitor.start()
        if modelsDownloaded { Task { await load() } }
        // Permissions can change in System Settings while we run.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemUsesFnKey = Hotkey.systemUsesFnKey
    }

    func requestAccessibility() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        accessibilityTrusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func requestMicrophone() async {
        micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Downloads anything missing (first time only), then loads both models into memory.
    func load() async {
        if case .loading = phase { return }
        let cleanup = cleanupModel, useCleanup = cleanupEnabled
        do {
            phase = .loading("Preparing speech model", 0)
            try await engine.speech.prepare { [weak self] p, s in
                Task { @MainActor in self?.phase = .loading(s, p * (useCleanup ? 0.5 : 1)) }
            }
            if useCleanup {
                try await engine.polisher.prepare(cleanup) { [weak self] p, s in
                    Task { @MainActor in self?.phase = .loading(s, 0.5 + p * 0.5) }
                }
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Hold to talk

    private func begin() {
        guard phase == .ready else {
            if case .failed = phase {} else if phase == .needsModels { NSSound.beep() }
            return
        }
        do {
            try capture.start()
        } catch {
            phase = .failed("Microphone: \(error.localizedDescription)")
            return
        }
        pressedAt = .now
        phase = .listening
        voice.isSettling = false
        overlay.show()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (level, bands) = self.capture.levels()
                self.voice.level = level
                self.voice.spectrum = bands
            }
        }
    }

    private func finish() {
        guard phase == .listening else { return }
        let released = ContinuousClock.now
        levelTimer?.invalidate()
        let samples = capture.stop()
        voice.level = 0
        voice.spectrum = []
        // A tap, not a hold: nothing to transcribe.
        if let pressedAt, released - pressedAt < .milliseconds(250) {
            overlay.hide()
            phase = .ready
            return
        }
        phase = .processing
        voice.isSettling = true
        let dictionary = dictionary, cleanup = cleanupEnabled
        Task {
            defer {
                overlay.hide()
                if phase == .processing { phase = .ready }
            }
            do {
                let result = try await engine.run(samples, dictionary: dictionary, cleanup: cleanup)
                guard !result.text.isEmpty else { return }
                TextInserter.insert(result.text)
                let wait = (ContinuousClock.now - released) / .seconds(1)
                let item = HistoryItem(text: result.text, rawText: result.rawText, audioSeconds: result.audioSeconds, waitSeconds: wait)
                history.insert(item, at: 0)
                if history.count > 500 { history.removeLast(history.count - 500) }
                save(history, to: "history.json")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        guard phase == .listening else { return }
        levelTimer?.invalidate()
        _ = capture.stop()
        overlay.hide()
        phase = .ready
    }

    func clearHistory() {
        history = []
        save(history, to: "history.json")
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Files

    private var folder: URL { URL.applicationSupportDirectory.appending(path: "Taki", directoryHint: .isDirectory) }

    private func save(_ value: some Encodable, to name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: folder.appending(path: name), options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// What the orb reads each frame.
final class VoiceLevels: OrbVoiceSource {
    var level: Float = 0
    var spectrum: [Float] = []
    var isSettling = false
}
