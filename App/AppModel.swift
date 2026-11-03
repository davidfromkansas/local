import Foundation
import Observation
import SwiftData
import TakiCore
import TakiEngine

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
    case ready
    case failed(String)
}

@Observable
final class AppModel {
    let engine = TranscriptionEngine()
    let hotMic: HotMicController
    let container: ModelContainer
    private(set) var modelStatus: ModelStatus = .notDownloaded
    var showSwipeBack = false

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.model: ASRModelChoice.parakeetUnified.rawValue,
            SettingsKey.timeout: 300.0,
            SettingsKey.cleanup: true,
            SettingsKey.debugFeed: Self.isSimulator,
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

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var modelChoice: ASRModelChoice {
        ASRModelChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.model) ?? "") ?? .parakeetUnified
    }

    var isModelReady: Bool { modelStatus == .ready }

    /// Loads (never downloads) the chosen model so the first dictation is fast.
    func loadModelsIfDownloaded() async {
        let choice = modelChoice
        guard await engine.isDownloaded(choice) else {
            modelStatus = .notDownloaded
            return
        }
        await prepareModels()
    }

    /// Downloads (first time only) and compiles the chosen model, reporting progress.
    func prepareModels() async {
        if case .downloading = modelStatus { return }
        let choice = modelChoice
        modelStatus = .downloading(0)
        do {
            try await engine.prepare(choice) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.modelStatus else { return }
                    self.modelStatus = .downloading(fraction)
                }
            }
            modelStatus = .ready
        } catch {
            modelStatus = .failed(error.localizedDescription)
        }
    }

    func modelChoiceChanged() async {
        await engine.unload()
        await loadModelsIfDownloaded()
    }

    func startSessionFromKeyboard() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.onboarded) else { return }
        hotMic.activate()
        if hotMic.phase != .inactive { showSwipeBack = true }
    }
}
