import AppKit

/// Modifier keys that work as a hold-to-talk button on their own.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .fn: "Fn (🌐)"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .fn: .function
        }
    }
}

/// Watches the hotkey in every app. Pressing any other key while holding it cancels, so normal
/// shortcuts (⌥+letter, ⌘+Tab) don't start a dictation. Needs Accessibility permission.
final class HotkeyMonitor {
    var hotkey: Hotkey = .rightOption
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
