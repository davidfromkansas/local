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
    @ObservationIgnored private var lastModelProgressAt = Date.now
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var prepareGeneration = 0
    /// Compiling the encoder the first time on a device can legitimately take a couple of minutes.
    private static let stallInterval: TimeInterval = 120
    var showSwipeBack = false

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.model: ASRModelChoice.parakeetUnified.rawValue,
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
        hotMic.modelChoice = { [weak self] in self?.modelChoice ?? .parakeetUnified }
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
        ASRModelChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.model) ?? "") ?? .parakeetUnified
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

        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, generation == self.prepareGeneration else { return }
                if Date.now.timeIntervalSince(self.lastModelProgressAt) > Self.stallInterval { self.modelStalled = true }
            }
        }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare speech model")
        defer {
            watchdog.cancel()
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
        case .success: modelStatus = .ready
        case let .failure(error): modelStatus = .failed(error.localizedDescription)
        }
    }

    private func apply(_ progress: PrepareProgress) {
        if progress.stage != modelProgress?.stage { modelStepStartedAt = .now }
        modelProgress = progress
        lastModelProgressAt = .now
        modelStalled = false
        modelStatus = progress.stage == .downloading ? .downloading(progress.fraction) : .loading
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
