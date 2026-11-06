import AVFoundation
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, download, keyboard, tryIt
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    // Persisted: toggling keyboard/Full Access in Settings can relaunch the app mid-onboarding.
    @AppStorage("onboardingStep") private var step: Step = .welcome
    @State private var micGranted = AVAudioApplication.shared.recordPermission == .granted
    @State private var tryText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.takiAccent : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .animation(.takiSnappy, value: step)

            ZStack {
                page(for: step)
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .takiSnappy, value: step)
        .interactiveDismissDisabled()
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(x: 40).combined(with: .opacity),
            removal: .offset(x: -40).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func page(for step: Step) -> some View {
        switch step {
        case .welcome:
            OnboardingPage(
                symbol: "waveform",
                title: "Talk. Taki types.",
                message: "Dictate into any app with the Taki keyboard. Speech is turned into text right on this iPhone — nothing is sent to the internet."
            ) {
                PrimaryButton("Get started") { advance() }
            }
        case .microphone:
            OnboardingPage(
                symbol: micGranted ? "checkmark.circle.fill" : "mic.fill",
                title: "Allow the microphone",
                message: "Taki only listens while you're dictating. The audio never leaves your phone."
            ) {
                if micGranted {
                    PrimaryButton("Continue") { advance() }
                } else {
                    PrimaryButton("Allow microphone") {
                        Task {
                            micGranted = await AVAudioApplication.requestRecordPermission()
                            advance()
                        }
                    }
                }
            }
        case .download:
            DownloadPage { advance() }
        case .keyboard:
            KeyboardSetupPage { advance() }
        case .tryIt:
            OnboardingPage(
                symbol: "text.cursor",
                title: "Try it",
                message: "Tap the box, switch to Taki with the 🌐 key, then tap the mic."
            ) {
                TextField("Tap here and dictate…", text: $tryText, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(14)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
                PrimaryButton("Finish") { onboarded = true }
            }
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }
}

private struct DownloadPage: View {
    @Environment(AppModel.self) private var model
    var onContinue: () -> Void

    var body: some View {
        OnboardingPage(
            symbol: model.isModelReady ? "checkmark.circle.fill" : "arrow.down.circle",
            title: model.isModelReady ? "Ready to go offline" : "Download the speech model",
            message: "\(model.modelChoice.displayName) · about \(model.modelChoice.approximateDownload). This happens once — use Wi-Fi. After that, Taki works with no internet."
        ) {
            switch model.modelStatus {
            case .notDownloaded:
                PrimaryButton("Download") { Task { await model.prepareModels() } }
            case .downloading, .loading:
                ModelSetupProgress()
            case .ready:
                PrimaryButton("Continue") { onContinue() }
            case let .failed(message):
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                if !model.setupLog.isEmpty { SetupLogView() }
                PrimaryButton("Try again") { Task { await model.prepareModels(restart: true) } }
            }
        }
    }
}

/// Progress for the model download/load, step by step, with a way out if it stops moving.
struct ModelSetupProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if case let .downloading(fraction) = model.modelStatus {
                ProgressView(value: fraction)
                    .animation(.linear(duration: 0.2), value: fraction)
            } else {
                ProgressView()
            }
            TimelineView(.periodic(from: model.modelStepStartedAt, by: 1)) { context in
                Text(statusLine(now: context.date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if model.modelStalled {
                Text("This is taking longer than it should.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Start over") { Task { await model.prepareModels(restart: true) } }
                    .buttonStyle(.bordered)
            }
            SetupLogView()
        }
        .frame(maxWidth: .infinity)
    }

    private func statusLine(now: Date) -> String {
        let elapsed = Int(max(0, now.timeIntervalSince(model.modelStepStartedAt)))
        let clock = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        switch model.modelProgress?.stage {
        case .downloading, nil:
            if case let .downloading(fraction) = model.modelStatus {
                return "Downloading… \(Int(fraction * 100))% · keep Taki open"
            }
            return "Getting the model ready… \(clock)"
        case .loadingModel:
            return "Getting the model ready for this iPhone… \(clock)\nThe first time, this can take a couple of minutes."
        case .loadingVAD:
            return "Loading the voice detector… \(clock)"
        case .warmingUp:
            return "Almost ready… \(clock)"
        }
    }
}

private struct KeyboardSetupPage: View {
    var onContinue: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingPage(
            symbol: "keyboard",
            title: "Turn on the Taki keyboard",
            message: "Three quick switches in Settings."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SetupStep(number: 1, text: "Tap **Open Settings** below, then **Keyboards**")
                SetupStep(number: 2, text: "Turn on **Taki**")
                SetupStep(number: 3, text: "Turn on **Allow Full Access** — Taki needs it to talk to this app. Your words stay on your phone.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 16))

            Text("Or: Settings › General › Keyboard › Keyboards › Add New Keyboard › Taki")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PrimaryButton("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("I've done this") { onContinue() }
                .font(.body.weight(.medium))
        }
    }
}

private struct SetupStep: View {
    var number: Int
    var text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.takiAccent, in: .circle)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingPage<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(Color.takiAccent)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 72)
                    .padding(.top, 48)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 16) { actions }
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct PrimaryButton: View {
    var title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

/// The setup steps as raw, terminal-style output that scrolls as lines arrive.
struct SetupLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.setupLog.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
            }
            .frame(height: 150)
            .background(Color(white: 0.09), in: .rect(cornerRadius: 12))
            .onChange(of: model.setupLog.count, initial: true) {
                proxy.scrollTo(model.setupLog.count - 1, anchor: .bottom)
            }
        }
        .accessibilityLabel("Setup log")
    }
}
