import SwiftUI
import TakiCore

/// Full letter keyboard with Taki's mic key in the lower-right corner.
/// Tap mic → it lights up while dictating; tap again → text is typed in and the letters stay.
struct KeyboardView: View {
    let model: KeyboardModel

    private let spacing: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
                .frame(height: 34)
            GeometryReader { proxy in
                let unit = max(0, (proxy.size.width - spacing * 9 - 6) / 10)
                VStack(spacing: 11) {
                    keyRow(rows[0], unit: unit)
                    keyRow(rows[1], unit: unit)
                        .padding(.horizontal, model.layer == .letters ? (unit + spacing) / 2 : 0)
                    thirdRow(unit: unit)
                    bottomRow(unit: unit)
                }
                .padding(.horizontal, 3)
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status

    private var statusStrip: some View {
        HStack(spacing: 10) {
            if model.state == .recording {
                LevelWaveform(levels: model.levels, active: true, maxHeight: 20, mirrored: true)
                    .transition(.opacity)
            }
            Text(model.statusText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            if model.state == .recording {
                LevelWaveform(levels: model.levels, active: true, maxHeight: 20)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .animation(.takiSnappy, value: model.state)
        .animation(.takiSnappy, value: model.statusText)
    }

    // MARK: Rows

    private var rows: [[String]] {
        switch model.layer {
        case .letters: [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"], ["a", "s", "d", "f", "g", "h", "j", "k", "l"], ["z", "x", "c", "v", "b", "n", "m"]]
        case .numbers: [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbols: [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        }
    }

    private func keyRow(_ keys: [String], unit: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(keys, id: \.self) { key in
                let shown = model.layer == .letters && model.shift != .off ? key.uppercased() : key
                KeyButton(title: shown, label: shown) { model.type(key) }
            }
        }
    }

    private func thirdRow(unit: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Group {
                switch model.layer {
                case .letters:
                    KeyButton(systemImage: shiftImage, label: "Shift", kind: model.shift == .off ? .function : .active) { model.shiftTapped() }
                case .numbers:
                    KeyButton(title: "#+=", label: "More symbols", kind: .function) { model.layer = .symbols }
                case .symbols:
                    KeyButton(title: "123", label: "Numbers", kind: .function) { model.layer = .numbers }
                }
            }
            .frame(width: unit * 1.35)
            if model.layer != .letters { Spacer(minLength: 0) }
            HStack(spacing: spacing) {
                ForEach(rows[2], id: \.self) { key in
                    let shown = model.layer == .letters && model.shift != .off ? key.uppercased() : key
                    KeyButton(title: shown, label: shown) { model.type(key) }
                        .frame(width: model.layer == .letters ? unit : unit * 1.4)
                }
            }
            if model.layer != .letters { Spacer(minLength: 0) }
            KeyButton(systemImage: "delete.left", label: "Delete", kind: .function, repeats: true) { model.delete() }
                .frame(width: unit * 1.35)
        }
    }

    private func bottomRow(unit: CGFloat) -> some View {
        HStack(spacing: spacing) {
            KeyButton(title: model.layer == .letters ? "123" : "ABC", label: model.layer == .letters ? "Numbers" : "Letters", kind: .function) {
                model.layer = model.layer == .letters ? .numbers : .letters
            }
            .frame(width: unit * 1.3)
            if model.showsGlobeKey {
                KeyButton(systemImage: "globe", label: "Next keyboard", kind: .function) { model.advanceToNextKeyboard() }
                    .frame(width: unit * 1.1)
            }
            KeyButton(title: "space", label: "Space", fontSize: 16) { model.space() }
            KeyButton(title: "return", label: "Return", kind: .function, fontSize: 16) { model.returnKey() }
                .frame(width: unit * 1.9)
            MicKey(state: model.state, level: model.levels.last ?? 0) {
                model.micTapped()
            }
            .frame(width: unit * 1.3)
        }
    }

    private var shiftImage: String {
        switch model.shift {
        case .off: "shift"
        case .on: "shift.fill"
        case .locked: "capslock.fill"
        }
    }
}

// MARK: - Mic key

/// The hero key: lights up red while dictating, breathes with the voice level.
private struct MicKey: View {
    var state: KeyboardUIState
    var level: Float
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(state == .recording ? Color.takiRecording : KeyKind.function.fill)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                    .scaleEffect(state == .recording && !reduceMotion ? 1 + CGFloat(level) * 0.08 : 1)
                    .animation(.easeOut(duration: 0.08), value: level)
                // No spinner while finishing: the words are already in the field, so the mic just
                // breathes softly until the final text lands.
                Image(systemName: state == .recording ? "mic.fill" : "mic")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(iconColor)
                    .opacity(state == .processing ? 0.5 : 1)
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .processing && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleKeyStyle())
        .animation(.takiSnappy, value: state)
        .sensoryFeedback(.impact(weight: .medium), trigger: state == .recording)
        .accessibilityLabel(state == .recording ? "Stop dictation" : "Dictate")
    }

    private var iconColor: Color {
        switch state {
        case .recording: .white
        case .ready: .takiAccent
        case .notReady, .processing: .primary
        }
    }
}

private struct PressScaleKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.takiPress, value: configuration.isPressed)
    }
}

// MARK: - Keys

/// UIKit resolves dynamic colors off the main thread, so the providers must not be MainActor-isolated.
private enum KeyPalette {
    static let character = Color(uiColor: dynamic(light: .white, dark: UIColor(white: 0.42, alpha: 1)))
    static let function = Color(uiColor: dynamic(light: UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1), dark: UIColor(white: 0.27, alpha: 1)))

    nonisolated private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

enum KeyKind {
    case character, function, active

    var fill: Color {
        switch self {
        case .character, .active: KeyPalette.character
        case .function: KeyPalette.function
        }
    }

    var pressedFill: Color {
        switch self {
        case .character, .active: KeyKind.function.fill
        case .function: KeyKind.character.fill
        }
    }
}

private struct KeyButton: View {
    var title: String?
    var systemImage: String?
    var label: String
    var kind: KeyKind = .character
    var fontSize: CGFloat = 22
    var repeats = false
    var action: () -> Void

    init(title: String? = nil, systemImage: String? = nil, label: String, kind: KeyKind = .character, fontSize: CGFloat? = nil, repeats: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.label = label
        self.kind = kind
        self.fontSize = fontSize ?? (kind == .character ? 22 : 15)
        self.repeats = repeats
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .regular))
                } else if let title {
                    Text(title).font(.system(size: fontSize))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle(kind: kind))
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .accessibilityLabel(label)
    }
}

/// System-keyboard-like key: instant color swap on press (keys don't scale).
private struct KeyStyle: ButtonStyle {
    var kind: KeyKind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? kind.pressedFill : kind.fill)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
    }
}
