import SwiftUI

/// The hero control: one round button that is idle, listening (level ring), or thinking.
struct MicOrb: View {
    enum Mode: Equatable {
        case idle      // session not running — tap to start
        case ready     // session running — tap to dictate
        case recording // tap to finish
        case processing
    }

    var mode: Mode
    var level: Float
    var diameter: CGFloat = 76
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                // Level ring: grows with your voice. Transform + opacity only.
                Circle()
                    .fill(Color.takiRecording.opacity(0.22))
                    .scaleEffect(mode == .recording ? 1 + CGFloat(level) * (reduceMotion ? 0 : 0.42) : 0.8)
                    .opacity(mode == .recording ? (reduceMotion ? 0.6 : 0.4 + Double(level) * 0.6) : 0)
                    .animation(.easeOut(duration: 0.1), value: level)

                Circle()
                    .fill(fill)
                    .shadow(color: fill.opacity(mode == .idle ? 0 : 0.35), radius: 10, y: 4)

                Group {
                    if mode == .processing {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.regular)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: diameter * 0.36, weight: .semibold))
                            .foregroundStyle(mode == .idle ? Color.takiAccent : .white)
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: reduceMotion ? 1 : 0.92))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .takiSnappy, value: mode)
        .sensoryFeedback(trigger: mode) { old, new in
            switch (old, new) {
            case (_, .recording): .impact(weight: .medium)
            case (.recording, .processing): .impact(weight: .light)
            case (.processing, .ready): .success
            default: nil
            }
        }
        .disabled(mode == .processing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch mode {
        case .idle, .ready: "mic.fill"
        case .recording: "stop.fill"
        case .processing: "mic.fill"
        }
    }

    private var fill: Color {
        switch mode {
        case .idle: Color.takiAccent.opacity(0.14)
        case .ready, .processing: .takiAccent
        case .recording: .takiRecording
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .idle: "Start Taki"
        case .ready: "Start dictation"
        case .recording: "Stop dictation"
        case .processing: "Transcribing"
        }
    }
}

/// Scales down on press-in, springs back on release. Interruptible.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.takiPress, value: configuration.isPressed)
    }
}
