import UIKit

/// Haptic tap + system click on every key press-down, like Apple's keyboard.
/// Haptics in a keyboard extension need Full Access; without it only the click plays.
final class KeyFeedback {
    static let shared = KeyFeedback()

    var hapticsEnabled = false
    private var generator: UIImpactFeedbackGenerator?

    func attach(to view: UIView) {
        generator = UIImpactFeedbackGenerator(style: .light, view: view)
        generator?.prepare()
    }

    func press() {
        UIDevice.current.playInputClick()
        guard hapticsEnabled, let generator else { return }
        generator.impactOccurred()
        generator.prepare()
    }
}

/// Opts the keyboard into `playInputClick()` (respects the user's Keyboard Clicks setting).
final class TakiInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
