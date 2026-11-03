import SwiftUI
import TakiCore

struct KeyboardView: View {
    let model: KeyboardModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Text(model.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.takiSnappy, value: model.statusText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 14)
                .padding(.horizontal, 16)

            Spacer(minLength: 8)

            HStack(spacing: 18) {
                LevelWaveform(levels: model.levels, active: model.state == .recording, mirrored: true)
                MicOrb(mode: orbMode, level: model.levels.last ?? 0, diameter: 78) {
                    if model.micTapped() { openURL(KeyboardModel.startURL) }
                }
                LevelWaveform(levels: model.levels, active: model.state == .recording)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if model.showsGlobeKey {
                    KeyButton(systemImage: "globe", label: "Next keyboard", width: 44) { model.advanceToNextKeyboard() }
                }
                KeyButton(title: "space", label: "Space") { model.insertText(" ") }
                KeyButton(systemImage: "delete.left", label: "Delete", width: 52, repeats: true) { model.deleteBackward() }
                KeyButton(systemImage: "return", label: "Return", width: 64) { model.insertText("\n") }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var orbMode: MicOrb.Mode {
        switch model.state {
        case .notReady: .idle
        case .ready: .ready
        case .recording: .recording
        case .processing: .processing
        }
    }
}

private struct KeyButton: View {
    var title: String?
    var systemImage: String?
    var label: String
    var width: CGFloat?
    var repeats = false
    var action: () -> Void

    init(title: String? = nil, systemImage: String? = nil, label: String, width: CGFloat? = nil, repeats: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.label = label
        self.width = width
        self.repeats = repeats
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .regular))
                } else if let title {
                    Text(title).font(.system(size: 16))
                }
            }
            .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle())
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .accessibilityLabel(label)
    }
}

/// System-keyboard-like key: instant darken on press (keys don't scale).
private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Color(uiColor: .systemGray4) : Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
    }
}
