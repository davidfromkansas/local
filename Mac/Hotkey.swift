import AppKit

/// Keys that work as a hold-to-talk button on their own. Fn is the default, like Wispr Flow.
enum Hotkey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn (🌐)"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .fn: .function
        }
    }

    /// macOS also acts on a lone Fn press (emoji picker, dictation…) unless
    /// System Settings › Keyboard › "Press 🌐 key to" is "Do Nothing" (`AppleFnUsageType` 0).
    static var systemUsesFnKey: Bool {
        // Unset means the factory default, which System Settings shows as "Do Nothing".
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 0) != 0
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// Watches the hotkey in every app. Pressing any other key while holding it cancels, so normal
/// shortcuts (⌥+letter, ⌘+Tab) don't start a dictation. Needs Accessibility permission.
final class HotkeyMonitor {
    var hotkey: Hotkey = .fn
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onInterrupt: () -> Void = {}
    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.handleOtherKey() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keys($0); return $0 },
        ].compactMap(\.self)
    }

    private func handleFlags(_ event: NSEvent) {
        if event.keyCode == hotkey.keyCode {
            let down = event.modifierFlags.contains(hotkey.flag)
            guard down != isDown else { return }
            isDown = down
            down ? onPress() : onRelease()
        } else if isDown {
            // Another modifier joined in: this is a shortcut, not dictation.
            isDown = false
            onInterrupt()
        }
    }

    private func handleOtherKey() {
        guard isDown else { return }
        isDown = false
        onInterrupt()
    }
}
