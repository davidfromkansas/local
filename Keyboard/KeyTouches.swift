import SwiftUI
import UIKit
import os

/// All key touches go through one multi-touch UIKit view laid over the SwiftUI keyboard (a sibling of the
/// hosting view, not inside it: SwiftUI swallowed touches in the gaps between keys). Per-key SwiftUI
/// gestures also dropped very short taps and taps during re-renders (after shift, return, 123/ABC).
/// A touch fires on touch-down and goes to the nearest key, so the gaps between keys have no dead zones.
@Observable
final class KeyTouches {
    /// KeyboardView's root space, which lines up with `KeyTouchView` (both fill the input view).
    nonisolated static let space = "keyboard"
    private static let reach: CGFloat = 12
    private static let log = Logger(subsystem: "com.davidfromkansas.taki.keyboard", category: "touches")

    struct Key {
        var id: String
        var token: UUID
        var frame: CGRect
        var repeats: Bool
        var action: () -> Void
        var wordRepeat: (() -> Void)?
    }

    private(set) var pressed: Set<String> = []
    @ObservationIgnored var enabled = true
    @ObservationIgnored private var keys: [String: Key] = [:]
    @ObservationIgnored private var active: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var repeaters: [String: Task<Void, Never>] = [:]

    func register(_ key: Key) { keys[key.id] = key }

    func unregister(_ id: String, token: UUID) {
        guard keys[id]?.token == token else { return }
        keys[id] = nil
        release(id, force: true)
    }

    func began(_ touch: UITouch, at point: CGPoint) {
        let key = enabled ? nearest(to: point) : nil
        Self.log.debug("touch \(point.x, format: .fixed(precision: 1)),\(point.y, format: .fixed(precision: 1)) -> \(key?.id ?? "none", privacy: .public) of \(self.keys.count)")
        guard let key else { return }
        active[ObjectIdentifier(touch)] = key.id
        pressed.insert(key.id)
        KeyFeedback.shared.press()
        key.action()
        if key.repeats { startRepeating(key) }
    }

    func ended(_ touch: UITouch) {
        guard let id = active.removeValue(forKey: ObjectIdentifier(touch)) else { return }
        release(id, force: false)
    }

    private func release(_ id: String, force: Bool) {
        if force { active = active.filter { $0.value != id } }
        guard !active.values.contains(id) else { return }
        pressed.remove(id)
        repeaters.removeValue(forKey: id)?.cancel()
    }

    func handles(_ point: CGPoint) -> Bool { enabled && nearest(to: point) != nil }

    private func nearest(to point: CGPoint) -> Key? {
        var best: (key: Key, distance: CGFloat)?
        for key in keys.values {
            let dx = max(key.frame.minX - point.x, 0, point.x - key.frame.maxX)
            let dy = max(key.frame.minY - point.y, 0, point.y - key.frame.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= Self.reach, distance < best?.distance ?? .infinity { best = (key, distance) }
        }
        return best?.key
    }

    /// Like Apple's delete: a short burst of single repeats, then whole words while held.
    private func startRepeating(_ key: Key) {
        repeaters[key.id]?.cancel()
        repeaters[key.id] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            var count = 0
            while !Task.isCancelled {
                if count < 8 || key.wordRepeat == nil {
                    key.action()
                    try? await Task.sleep(for: .milliseconds(85))
                } else {
                    key.wordRepeat?()
                    try? await Task.sleep(for: .milliseconds(170))
                }
                count += 1
            }
        }
    }
}

final class KeyTouchView: UIView {
    private let touches: KeyTouches?

    init(touches: KeyTouches) {
        self.touches = touches
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only claims touches near a key; the mic bar and the orb fall through to SwiftUI.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        touches?.handles(point) ?? false
    }

    override func touchesBegan(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set { touches?.began(touch, at: touch.location(in: self)) }
    }

    override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set { touches?.ended(touch) }
    }

    override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set { touches?.ended(touch) }
    }
}
