import Foundation
import Observation
import SwiftData
import TakiCore
import TakiEngine
import UIKit

enum SettingsKey {
    static let model = "modelChoice"
    static let timeout = "sessionTimeout"
    static let cleanup = "cleanupEnabled"
    static let onboarded = "hasCompletedOnboarding"
    static let debugFeed = "debugUseFileFeed"
}

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)
    /// Already on disk; compiling/loading into memory (every launch).
    case loading
    case ready
    case failed(String)
}

@Observable
final class AppModel {
    let engine = TranscriptionEngine()
    let hotMic: HotMicController
    let container: ModelContainer
    private(set) var modelStatus: ModelStatus = .notDownloaded
    /// What the model setup is doing right now (nil when idle).
    private(set) var modelProgress: PrepareProgress?
    /// When the current setup step began, for the elapsed-time readout.
    private(set) var modelStepStartedAt = Date.now
    /// No progress for `stallInterval`: offer to start over.
    private(set) var modelStalled = false
    /// Terminal-style lines under the setup progress, so people can see it's really working.
    private(set) var setupLog: [String] = []
    @ObservationIgnored private var lastModelProgressAt = Date.now
    @ObservationIgnored private var setupStartedAt = Date.now
    @ObservationIgnored private var compileStartedAt = Date.now
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var prepareGeneration = 0
    /// No new bytes for this long while downloading counts as stuck.
    private static let stallInterval: TimeInterval = 120
    private static let compileStallInterval: TimeInterval = 600
    var showSwipeBack = false

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.model: ASRModelChoice.parakeetTDTv2.rawValue,
            SettingsKey.timeout: 0.0, // Never: stay on until the user ends it
            SettingsKey.cleanup: true,
            SettingsKey.debugFeed: false,
        ])
        do {
            container = try ModelContainer(for: TranscriptRecord.self, DictionaryWord.self)
        } catch {
            fatalError("Could not open the history database: \(error)")
        }
        hotMic = HotMicController(engine: engine)
        hotMic.modelChoice = { [weak self] in self?.modelChoice ?? .parakeetTDTv2 }
        hotMic.dictionaryProvider = { [container] in
            let words = (try? container.mainContext.fetch(FetchDescriptor<DictionaryWord>())) ?? []
            return words.map(\.entry)
        }
        hotMic.onFinished = { [container] output in
            container.mainContext.insert(TranscriptRecord(output: output))
            try? container.mainContext.save()
        }
    }

    var modelChoice: ASRModelChoice {
        ASRModelChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.model) ?? "") ?? .parakeetTDTv2
    }

    /// Picks another model and loads it, abandoning whatever was loading.
    func switchModel(to choice: ASRModelChoice) async {
        UserDefaults.standard.set(choice.rawValue, forKey: SettingsKey.model)
        await prepareModels(restart: true)
    }

    var isModelReady: Bool { modelStatus == .ready }

    /// Loads the chosen model at launch if it's on disk, so the first dictation is fast.
    func loadModelsIfDownloaded() async {
        guard await engine.isDownloaded(modelChoice) else {
            if !preparing { modelStatus = .notDownloaded }
            return
        }
        await prepareModels()
    }

    /// Downloads (first time only) and loads the chosen model, reporting what it's doing.
    /// `restart` abandons a load that seems stuck and starts it over.
    func prepareModels(restart: Bool = false) async {
        guard restart || (!preparing && modelStatus != .ready) else { return }
        prepareGeneration += 1
        let generation = prepareGeneration
        preparing = true
        let choice = modelChoice
        if await engine.isDownloaded(choice) {
            modelStatus = .loading
            modelProgress = PrepareProgress(stage: .loadingModel, fraction: 0)
        } else {
            modelStatus = .downloading(0)
            modelProgress = PrepareProgress(stage: .downloading, fraction: 0)
        }
        modelStalled = false
        modelStepStartedAt = .now
        lastModelProgressAt = .now
        if restart {
            log("— starting over —")
        } else {
            setupStartedAt = .now
            setupLog = []
        }
        log("$ taki setup \(choice.rawValue)")
        log("model: \(choice.displayName) · \(choice.approximateDownload)")
        if modelStatus == .loading {
            compileStartedAt = .now
            log("model files found on this iPhone")
            log("building the model for this iPhone's chip (first time only)…")
        } else {
            log("model not on this iPhone yet, downloading from huggingface.co")
        }
        let meter = meterDownload(generation: generation)

        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, generation == self.prepareGeneration else { return }
                // Compiling reports nothing until it's done, and can take minutes on a phone.
                let limit = self.modelProgress?.stage == .downloading ? Self.stallInterval : Self.compileStallInterval
                if Date.now.timeIntervalSince(self.lastModelProgressAt) > limit { self.modelStalled = true }
            }
        }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare speech model")
        defer {
            watchdog.cancel()
            meter.cancel()
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }

        let result: Result<Void, Error>
        do {
            try await engine.prepare(choice, restart: restart) { [weak self] progress in
                Task { @MainActor in
                    guard let self, generation == self.prepareGeneration, self.preparing else { return }
                    self.apply(progress)
                }
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        guard generation == prepareGeneration else { return }  // superseded by a restart
        preparing = false
        modelProgress = nil
        modelStalled = false
        switch result {
        case .success:
            log("ready in \(Self.clock(Date.now.timeIntervalSince(setupStartedAt))) · Taki now works offline")
            modelStatus = .ready
        case let .failure(error):
            log("error: \(error.localizedDescription)")
            modelStatus = .failed(error.localizedDescription)
        }
    }

    private func log(_ line: String) {
        setupLog.append("[\(Self.clock(Date.now.timeIntervalSince(setupStartedAt)))] \(line)")
        if setupLog.count > 300 { setupLog.removeFirst(setupLog.count - 300) }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Every 2 s, measures the bytes actually on disk to log real download speed, and notes
    /// long compiles so the log never goes quiet.
    private func meterDownload(generation: Int) -> Task<Void, Never> {
        let directory = engine.modelsDirectory
        return Task { [weak self] in
            let startBytes = await Self.bytesOnDisk(directory)
            var lastBytes = startBytes
            var idleSeconds = 0
            var compileTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let bytes = await Self.bytesOnDisk(directory)
                guard let self, generation == self.prepareGeneration, self.preparing else { return }
                switch self.modelProgress?.stage {
                case .downloading:
                    if bytes > lastBytes {
                        idleSeconds = 0
                        lastModelProgressAt = .now
                        let percent = Int((self.modelProgress?.fraction ?? 0) * 100)
                        self.log("↓ \(Self.size(bytes - startBytes)) · \(Self.size((bytes - lastBytes) / 2))/s · \(percent)%")
                    } else {
                        idleSeconds += 2
                        if idleSeconds % 10 == 0 { self.log("… no data for \(idleSeconds) s, waiting for the network") }
                    }
                case .loadingModel:
                    compileTicks += 1
                    if compileTicks % 8 == 0 {
                        let name = self.modelProgress?.detail ?? ""
                        let seconds = Int(Date.now.timeIntervalSince(self.compileStartedAt))
                        self.log("still building\(name.isEmpty ? "" : " \(name)")… \(seconds) s")
                    }
                default:
                    break
                }
                lastBytes = bytes
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @concurrent nonisolated private static func bytesOnDisk(_ directory: URL) async -> Int64 {
        directorySize(directory)
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func apply(_ progress: PrepareProgress) {
        logChanges(from: modelProgress, to: progress)
        if progress.stage != modelProgress?.stage { modelStepStartedAt = .now }
        modelProgress = progress
        lastModelProgressAt = .now
        modelStalled = false
        modelStatus = progress.stage == .downloading ? .downloading(progress.fraction) : .loading
    }

    private func logChanges(from previous: PrepareProgress?, to progress: PrepareProgress) {
        switch progress.stage {
        case .downloading:
            if progress.detail == "listing", previous?.detail != "listing" { log("fetching the file list…") }
            guard let done = progress.completedFiles, let total = progress.totalFiles else { return }
            if total == 0 {
                if previous?.totalFiles != 0 { log("all files already downloaded") }
            } else {
                if previous?.totalFiles != total { log("\(total) files to download") }
                if done > (previous?.completedFiles ?? 0) { log("✓ file \(done)/\(total) downloaded") }
            }
        case .loadingModel:
            if previous?.stage != .loadingModel {
                if let done = progress.completedFiles, let total = progress.totalFiles {
                    if total == 0 {
                        log("all files already downloaded")
                    } else if done > (previous?.completedFiles ?? 0) {
                        log("✓ file \(done)/\(total) downloaded")
                    }
                }
                compileStartedAt = .now
                log("building the model for this iPhone's chip (first time only, can take a few minutes)…")
            }
            guard previous?.stage != .loadingModel || previous?.detail != progress.detail else { return }
            if previous?.stage == .loadingModel, let name = previous?.detail, !name.isEmpty {
                log("✓ \(name) ready in \(Int(Date.now.timeIntervalSince(compileStartedAt))) s")
            }
            if !progress.detail.isEmpty {
                compileStartedAt = .now
                log("compiling \(progress.detail) for this iPhone…")
            }
        case .loadingVAD:
            if previous?.stage != .loadingVAD {
                if previous?.stage == .loadingModel {
                    log("✓ model built in \(Int(Date.now.timeIntervalSince(compileStartedAt))) s")
                }
                log("loading the voice detector (Silero VAD)")
            }
        case .warmingUp:
            if previous?.stage != .warmingUp { log("warming up the model") }
        }
    }

    func modelChoiceChanged() async {
        await engine.unload()
        modelStatus = .notDownloaded
        await loadModelsIfDownloaded()
    }

    func startSessionFromKeyboard() {
        hotMic.activate()
        // During onboarding's "Try it" step the keyboard is inside Taki itself, so there's nowhere to swipe back to.
        if hotMic.phase != .inactive, UserDefaults.standard.bool(forKey: SettingsKey.onboarded) { showSwipeBack = true }
    }
}
