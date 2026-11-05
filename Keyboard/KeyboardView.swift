import SwiftUI
import TakiCore

/// Standard iPhone-style QWERTY keyboard with Taki's mic on its own row above the keys.
struct KeyboardView: View {
    let model: KeyboardModel

    private let spacing: CGFloat = 6
    private let rowSpacing: CGFloat = 11

    var body: some View {
        VStack(spacing: 0) {
            MicRow(model: model)
                .frame(height: 50)
            GeometryReader { proxy in
                let unit = max(0, (proxy.size.width - 6 - spacing * 9) / 10)
                VStack(spacing: rowSpacing) {
                    characterRow(rows[0])
                    characterRow(rows[1])
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

    // MARK: Rows

    private var rows: [[String]] {
        switch model.layer {
        case .letters: [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"], ["a", "s", "d", "f", "g", "h", "j", "k", "l"], ["z", "x", "c", "v", "b", "n", "m"]]
        case .numbers: [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbols: [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        }
    }

    private func shown(_ key: String) -> String {
        model.layer == .letters && model.shift != .off ? key.uppercased() : key
    }

    private func characterRow(_ keys: [String]) -> some View {
        HStack(spacing: spacing) {
            ForEach(keys, id: \.self) { key in
                KeyButton(title: shown(key), label: shown(key), popup: true) { model.type(key) }
            }
        }
    }

    private func thirdRow(unit: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Group {
                switch model.layer {
                case .letters:
                    KeyButton(systemImage: shiftImage, label: model.shift == .locked ? "Caps lock" : "Shift", kind: model.shift == .off ? .function : .active) { model.shiftTapped() }
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
                    KeyButton(title: shown(key), label: shown(key), popup: true) { model.type(key) }
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
            KeyButton(title: model.layer == .letters ? "123" : "ABC", label: model.layer == .letters ? "Numbers" : "Letters", kind: .function, fontSize: 16) {
                model.layer = model.layer == .letters ? .numbers : .letters
            }
            .frame(width: unit * (model.showsGlobeKey ? 1.25 : 2.5) + (model.showsGlobeKey ? 0 : spacing))
            if model.showsGlobeKey {
                KeyButton(systemImage: "globe", label: "Next keyboard", kind: .function) { model.advanceToNextKeyboard() }
                    .frame(width: unit * 1.25)
            }
            KeyButton(title: "space", label: "Space", fontSize: 16) { model.space() }
            let returnLabel = model.returnLabel
            KeyButton(title: returnLabel.title, label: returnLabel.title, kind: returnLabel.isPrimary ? .primary : .function, fontSize: 16) { model.returnKey() }
                .frame(width: unit * 2.5 + spacing)
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

// MARK: - Mic row

/// Toolbar-style row above the keys: status on the left, mic in the middle, voice level on the right.
private struct MicRow: View {
    let model: KeyboardModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Text(model.statusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 72)
                LevelWaveform(levels: model.levels, active: model.state == .recording, maxHeight: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            .padding(.horizontal, 14)
            MicButton(state: model.state, level: model.levels.last ?? 0) {
                KeyFeedback.shared.press()
                model.micTapped()
            }
        }
        .animation(.takiSnappy, value: model.state)
        .animation(.takiSnappy, value: model.statusText)
    }
}

/// The hero control: lights up red while dictating and breathes with the voice level.
private struct MicButton: View {
    var state: KeyboardUIState
    var level: Float
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let diameter: CGFloat = 40

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.takiRecording.opacity(0.25))
                    .scaleEffect(state == .recording && !reduceMotion ? 1 + CGFloat(level) * 0.35 : 1)
                    .opacity(state == .recording ? 1 : 0)
                    .animation(.easeOut(duration: 0.1), value: level)
                Circle()
                    .fill(fill)
                Image(systemName: state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state == .notReady ? Color.takiAccent : .white)
                    .opacity(state == .processing ? 0.6 : 1)
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .processing && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: diameter, height: diameter)
            .frame(width: 64, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: reduceMotion ? 1 : 0.9))
        .sensoryFeedback(.impact(weight: .medium), trigger: state == .recording)
        .accessibilityLabel(state == .recording ? "Stop dictation" : "Dictate")
    }

    private var fill: Color {
        switch state {
        case .notReady: Color.takiAccent.opacity(0.16)
        case .ready, .processing: .takiAccent
        case .recording: .takiRecording
        }
    }
}

// MARK: - Keys

/// UIKit resolves dynamic colors off the main thread, so the providers must not be MainActor-isolated.
private enum KeyPalette {
    static let character = Color(uiColor: dynamic(light: .white, dark: UIColor(white: 0.42, alpha: 1)))
    static let function = Color(uiColor: dynamic(light: UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1), dark: UIColor(white: 0.27, alpha: 1)))
    static let primary = Color(uiColor: .systemBlue)

    nonisolated private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

enum KeyKind {
    case character, function, active, primary

    var fill: Color {
        switch self {
        case .character, .active: KeyPalette.character
        case .function: KeyPalette.function
        case .primary: KeyPalette.primary
        }
    }

    var pressedFill: Color {
        switch self {
        case .character, .active: KeyPalette.function
        case .function: KeyPalette.character
        case .primary: KeyPalette.function
        }
    }

    var foreground: Color { self == .primary ? .white : .primary }
}

private struct KeyButton: View {
    var title: String?
    var systemImage: String?
    var label: String
    var kind: KeyKind
    var fontSize: CGFloat
    var repeats: Bool
    var popup: Bool
    var action: () -> Void

    init(title: String? = nil, systemImage: String? = nil, label: String, kind: KeyKind = .character, fontSize: CGFloat? = nil, repeats: Bool = false, popup: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.label = label
        self.kind = kind
        self.fontSize = fontSize ?? (kind == .character ? 22 : 15)
        self.repeats = repeats
        self.popup = popup
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
        .buttonStyle(KeyStyle(kind: kind, popupText: popup ? title : nil))
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .accessibilityLabel(label)
    }
}

/// System-keyboard-like key: instant color swap (or letter popup) on press, haptic + click on touch-down.
private struct KeyStyle: ButtonStyle {
    var kind: KeyKind
    var popupText: String?

    func makeBody(configuration: Configuration) -> some View {
        let showPopup = configuration.isPressed && popupText != nil
        configuration.label
            .foregroundStyle(kind.foreground)
            .opacity(showPopup ? 0 : 1)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed && popupText == nil ? kind.pressedFill : kind.fill)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
            .overlay(alignment: .bottom) {
                if showPopup, let popupText {
                    KeyPopup(text: popupText)
                }
            }
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { KeyFeedback.shared.press() }
            }
    }
}

/// Enlarged callout above a pressed letter key, like Apple's.
private struct KeyPopup: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 34))
            .foregroundStyle(.primary)
            .frame(minWidth: 46, maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, -4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(KeyKind.character.fill)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            )
            .offset(y: -50)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
