import AppKit
import MetalKit

/// The Taki orb in a small floating window near the bottom of the screen while listening. It never
/// takes focus, so the text still goes to the app you were typing in.
final class OrbOverlay {
    private let panel: NSPanel
    private let renderer: OrbRenderer?
    private let view: MTKView
    private let tuning: OrbTuningStore

    init(voice: VoiceLevels, tuning: OrbTuningStore) {
        self.tuning = tuning
        let size = NSSize(width: CGFloat(tuning.tuning.size), height: CGFloat(tuning.tuning.size))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        view = MTKView(frame: NSRect(origin: .zero, size: size), device: OrbRenderer.device)
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 120
        view.isPaused = true
        view.autoresizingMask = [.width, .height]
        renderer = OrbRenderer(model: voice)
        renderer?.tuningSource = { [weak tuning] in tuning?.tuning ?? .standard }
        renderer?.attach(to: view)
        panel.contentView = view
    }

    /// Size and spot from the Orb Tuner.
    func layout() {
        let side = CGFloat(tuning.tuning.size)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: frame.midX - side / 2, y: frame.minY + CGFloat(tuning.tuning.bottom), width: side, height: side),
                       display: true)
    }

    func show() {
        layout()
        // The violet rim keeps the deep-purple orb readable over any window, light or dark.
        renderer?.dark = true
        renderer?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.isPaused = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel, view] in
            MainActor.assumeIsolated {
                guard panel.alphaValue == 0 else { return }
                panel.orderOut(nil)
                view.isPaused = true
            }
        }
    }
}
