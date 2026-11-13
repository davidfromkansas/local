import AppKit
import MetalKit

/// The Taki orb in a small floating window near the bottom of the screen while listening. It never
/// takes focus, so the text still goes to the app you were typing in.
final class OrbOverlay {
    private let panel: NSPanel
    private let renderer: OrbRenderer?
    private let view: MTKView

    init(voice: VoiceLevels) {
        let size = NSSize(width: 220, height: 220)
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
        renderer = OrbRenderer(model: voice)
        renderer?.attach(to: view)
        panel.contentView = view
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 24))
        }
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
