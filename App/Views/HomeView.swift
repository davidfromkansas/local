import SwiftUI
import TakiCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var tryText = ""
    @State private var levels = [Float](repeating: 0, count: 14)

    private var hotMic: HotMicController { model.hotMic }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    sessionCard
                    if !model.isModelReady { modelCard }
                    tryItCard
                    if let error = hotMic.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Taki")
            .onChange(of: hotMic.level) { _, level in
                levels.removeFirst()
                levels.append(level)
            }
        }
    }

    private var sessionCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                LevelWaveform(levels: levels, active: hotMic.phase == .capturing, mirrored: true)
                MicOrb(mode: orbMode, level: hotMic.level, diameter: 96) {
                    if hotMic.phase == .inactive { hotMic.activate() } else { hotMic.toggleCapture() }
                }
                .disabled(!model.isModelReady && hotMic.phase == .inactive)
                LevelWaveform(levels: levels, active: hotMic.phase == .capturing)
            }
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text(statusTitle)
                    .font(.headline)
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusDetail(now: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(.takiSnappy, value: hotMic.phase)

            if hotMic.phase != .inactive {
                Button("End session", role: .destructive) { hotMic.endSession() }
                    .buttonStyle(.bordered)
                    .transition(.opacity)
            }

            if let last = hotMic.lastText, !last.isEmpty {
                Text("“\(last)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 24))
        .animation(.takiSnappy, value: hotMic.phase)
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speech model not ready", systemImage: "arrow.down.circle")
                .font(.headline)
            switch model.modelStatus {
            case let .downloading(fraction):
                ProgressView(value: fraction)
            case let .failed(message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try again") { Task { await model.prepareModels() } }
            default:
                Text("Download \(model.modelChoice.displayName) (\(model.modelChoice.approximateDownload)) once, over Wi-Fi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Download") { Task { await model.prepareModels() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 24))
    }

    private var tryItCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it here")
                .font(.headline)
            TextField("Switch to the Taki keyboard (🌐) and tap the mic…", text: $tryText, axis: .vertical)
                .lineLimit(3...8)
                .padding(12)
                .background(.background, in: .rect(cornerRadius: 12))
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 24))
    }

    private var orbMode: MicOrb.Mode {
        switch hotMic.phase {
        case .inactive: .idle
        case .armed: .ready
        case .capturing: .recording
        case .processing: .processing
        }
    }

    private var statusTitle: String {
        switch hotMic.phase {
        case .inactive: "Session off"
        case .armed: "Ready — dictate from any app"
        case .capturing: "Listening…"
        case .processing: "Writing it down…"
        }
    }

    private func statusDetail(now: Date) -> String {
        switch hotMic.phase {
        case .inactive:
            return model.isModelReady ? "Tap the mic to start a session, or just tap the mic on the Taki keyboard." : "Download the speech model to get started."
        case .armed:
            guard let expiresAt = hotMic.expiresAt else { return "Stays on until you end it." }
            let remaining = max(0, Int(expiresAt.timeIntervalSince(now)))
            return String(format: "Ends after %d:%02d of no use", remaining / 60, remaining % 60)
        case .capturing:
            return "Tap the mic again when you're done."
        case .processing:
            return "All on this iPhone."
        }
    }
}
