import SwiftUI
import TakiEngine

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.model) private var modelChoice = ASRModelChoice.parakeetUnified.rawValue
    @AppStorage(SettingsKey.timeout) private var timeout = 0.0
    @AppStorage(SettingsKey.cleanup) private var cleanup = true
    @AppStorage(SettingsKey.debugFeed) private var debugFeed = false
    @AppStorage(SettingsKey.onboarded) private var onboarded = true

    private static let timeouts: [(String, Double)] = [
        ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900), ("1 hour", 3600), ("Never", 0),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Speech model", selection: $modelChoice) {
                        ForEach(ASRModelChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice.rawValue)
                        }
                    }
                    LabeledContent("Status", value: statusText)
                    if model.modelStatus == .notDownloaded {
                        Button("Download \(model.modelChoice.approximateDownload)") { Task { await model.prepareModels() } }
                    }
                } header: {
                    Text("Recognition")
                } footer: {
                    Text("Everything runs on this iPhone. Parakeet Unified is the most accurate; TDT v2 is the fallback.")
                }

                Section {
                    Picker("End session after", selection: $timeout) {
                        ForEach(Self.timeouts, id: \.1) { item in Text(item.0).tag(item.1) }
                    }
                } footer: {
                    Text("While a session is on, the mic stays ready in the background so the keyboard can start instantly. The orange dot shows when it's on.")
                }

                Section {
                    Toggle("Clean up text", isOn: $cleanup)
                } footer: {
                    Text("Removes “um” and “uh”, fixes punctuation, and handles “actually I mean…”. \(LLMCleanerStatus.text)")
                }

                #if DEBUG
                Section("Developer") {
                    Toggle("Use test audio instead of mic", isOn: $debugFeed)
                    Button("Show onboarding again") { onboarded = false }
                }
                #endif
            }
            .navigationTitle("Settings")
            .onChange(of: modelChoice) { Task { await model.modelChoiceChanged() } }
        }
    }

    private var statusText: String {
        switch model.modelStatus {
        case .notDownloaded: "Not downloaded"
        case let .downloading(fraction): "Downloading \(Int(fraction * 100))%"
        case .ready: "Ready, works offline"
        case .failed: "Failed"
        }
    }
}

private enum LLMCleanerStatus {
    static var text: String {
        LLMCleaner.isAvailable ? "Apple Intelligence polishes the result on-device." : "Apple Intelligence isn't available, so Taki uses its built-in rules."
    }
}
