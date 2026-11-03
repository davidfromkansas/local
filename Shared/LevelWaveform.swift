import SwiftUI

/// Bars driven by recent mic levels (newest at the inner edge).
struct LevelWaveform: View {
    var levels: [Float]
    var active: Bool
    var color: Color = .takiRecording
    var maxHeight: CGFloat = 40
    /// Mirror so the newest bar sits next to the mic on the left-hand side.
    var mirrored = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(active ? color : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: height(for: level))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: levels)
        .animation(.takiSnappy, value: active)
        .accessibilityHidden(true)
    }

    private var ordered: [Float] { mirrored ? levels.reversed() : levels }

    private func height(for level: Float) -> CGFloat {
        guard active else { return 3 }
        return max(3, CGFloat(level) * maxHeight)
    }
}
