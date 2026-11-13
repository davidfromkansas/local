import SwiftUI
import TakiCore
import TakiMacEngine

struct MenuContent: View {
    let model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if let wait = model.lastWait {
            Text("Last wait after release: \(wait, format: .number.precision(.fractionLength(2))) s")
        }
        if let last = model.history.first {
            Button("Copy last: \(last.text.prefix(40))") { model.copy(last.text) }
        }
        Divider()
        Picker("Hold to Talk Key", selection: Bindable(model).hotkey) {
            ForEach(Hotkey.allCases) { Text($0.displayName).tag($0) }
        }
        Divider()
        Button("Open Taki…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Quit Taki") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension MacModel {
    var statusText: String {
        switch phase {
        case .needsModels: "Set up Taki to start"
        case .loading(let step, let progress): "\(step)… \(Int(progress * 100))%"
        case .ready: "Hold \(hotkey.displayName) and talk"
        case .listening: "Listening…"
        case .processing: "Typing…"
        case .failed(let message): "Problem: \(message)"
        }
    }
}

struct MainWindow: View {
    @Bindable var model: MacModel

    var body: some View {
        TabView {
            Tab("Home", systemImage: "waveform") { HomeTab(model: model) }
            Tab("History", systemImage: "clock") { HistoryTab(model: model) }
            Tab("Dictionary", systemImage: "character.book.closed") { DictionaryTab(model: model) }
            Tab("Models", systemImage: "cpu") { ModelsTab(model: model) }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 560)
    }
}

private struct HomeTab: View {
    @Bindable var model: MacModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(model.statusText).foregroundStyle(.secondary) }
                if case .loading(_, let progress) = model.phase { ProgressView(value: progress) }
                if let wait = model.lastWait {
                    LabeledContent("Last wait after release") {
                        Text("\(wait, format: .number.precision(.fractionLength(2))) s").monospacedDigit()
                    }
                }
            }
            Section("Setup") {
                step("Microphone", done: model.micAllowed || model.phase == .listening) {
                    Button("Allow") { Task { await model.requestMicrophone() } }
                }
                step("Accessibility (to type into other apps)", done: model.accessibilityTrusted) {
                    Button("Open Settings") { model.requestAccessibility() }
                }
                step("Models downloaded (one time, then fully offline)", done: model.modelsDownloaded) {
                    Button("Download") { Task { await model.load() } }
                        .disabled({ if case .loading = model.phase { true } else { false } }())
                }
            }
            Section("Hold-to-talk key") {
                Picker("Key", selection: $model.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Click into any text field, hold the key, talk, and let go. Taki types what you said.")
                    .foregroundStyle(.secondary)
                if model.hotkey == .fn && model.systemUsesFnKey {
                    LabeledContent {
                        Button("Open Keyboard Settings") { Hotkey.openKeyboardSettings() }
                    } label: {
                        Text("macOS also uses Fn. Set “Press 🌐 key to” to “Do Nothing”.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func step(_ title: String, done: Bool, @ViewBuilder action: () -> some View) -> some View {
        LabeledContent {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { action() }
        } label: {
            Text(title)
        }
    }
}

private struct HistoryTab: View {
    let model: MacModel

    var body: some View {
        VStack(alignment: .leading) {
            if model.history.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "waveform", description: Text("Your dictations show up here."))
            } else {
                List(model.history) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text).textSelection(.enabled)
                        Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.audioSeconds, format: .number.precision(.fractionLength(1))) s spoken · \(item.waitSeconds, format: .number.precision(.fractionLength(2))) s wait")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Copy") { model.copy(item.text) }
                        Button("Copy what the speech model heard") { model.copy(item.rawText) }
                    }
                }
                Button("Clear History", role: .destructive) { model.clearHistory() }
            }
        }
    }
}

private struct DictionaryTab: View {
    @Bindable var model: MacModel
    @State private var term = ""
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Names and words Taki should always spell your way.").foregroundStyle(.secondary)
            HStack {
                TextField("Word (e.g. Taki)", text: $term)
                TextField("Replace with (optional)", text: $replacement)
                Button("Add") {
                    let word = term.trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty else { return }
                    let fix = replacement.trimmingCharacters(in: .whitespaces)
                    model.dictionary.append(DictionaryEntry(term: word, replacement: fix.isEmpty ? nil : fix))
                    term = ""
                    replacement = ""
                }
            }
            List {
                ForEach(model.dictionary, id: \.self) { entry in
                    Text(entry.replacement.map { "\(entry.term) → \($0)" } ?? entry.term)
                }
                .onDelete { model.dictionary.remove(atOffsets: $0) }
            }
        }
    }
}

private struct ModelsTab: View {
    @Bindable var model: MacModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Speech model") { Text("\(SpeechModel.displayName) · \(SpeechModel.approximateDownload)") }
                Text("Turns your recording into words after you let go of the key.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Clean up with a local AI model", isOn: $model.cleanupEnabled)
                Picker("Cleanup model", selection: $model.cleanupModel) {
                    ForEach(CleanupModelChoice.allCases) { Text("\($0.displayName) · \($0.approximateDownload)").tag($0) }
                }
                .disabled(!model.cleanupEnabled)
                Text("Fixes punctuation, removes “um”s and keeps only your correction when you change your mind. It never answers what you say.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Stored in") { Text(model.store.root.path(percentEncoded: false)).textSelection(.enabled).font(.caption) }
                Button("Reload models") { Task { await model.load() } }
            }
        }
        .formStyle(.grouped)
    }
}
