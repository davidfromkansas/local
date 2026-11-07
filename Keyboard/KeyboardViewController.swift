import SwiftUI
import UIKit
#if DEBUG
import os
#endif

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private let keyTouches = KeyTouches()
    private var host: UIHostingController<KeyboardView>?

    override func loadView() {
        let inputView = TakiInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        self.inputView = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyFeedback.shared.attach(to: view)
        model.insertText = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        model.deleteBackward = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.contextBeforeInput = { [weak self] in self?.textDocumentProxy.documentContextBeforeInput }
        model.advanceToNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        model.openURL = { [weak self] url in self?.openContainingApp(url) ?? false }

        let host = UIHostingController(rootView: KeyboardView(model: model, keyTouches: keyTouches))
        host.view.backgroundColor = .clear
        host.view.isMultipleTouchEnabled = true
        host.sizingOptions = []
        host.safeAreaRegions = []
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let height = view.heightAnchor.constraint(equalToConstant: 281)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)

        let touchView = KeyTouchView(touches: keyTouches)
        touchView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(touchView)
        NSLayoutConstraint.activate([
            touchView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            touchView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            touchView.topAnchor.constraint(equalTo: host.view.topAnchor),
            touchView.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        self.host = host
    }

    /// Keyboard extensions can't open URLs: SwiftUI's `openURL` and `extensionContext.open` silently do nothing.
    /// Walk the responder chain to the host `UIApplication` and call `open(_:options:completionHandler:)`
    /// through the Objective-C runtime (the method is marked unavailable for extensions at compile time).
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication, app.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(app.method(for: selector), to: Open.self)
                open(app, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        KeyFeedback.shared.hapticsEnabled = hasFullAccess
        model.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        model.start()
        #if DEBUG
        MemoryLog.start()
        #endif
    }

    /// iOS's edge-swipe recognizers on the keyboard window hold back touches near the screen edges
    /// (Q, A, P, the bottom row), which drops quick taps. Let touches through immediately.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        for recognizer in view.window?.gestureRecognizers ?? [] {
            recognizer.delaysTouchesBegan = false
        }
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if model.showsGlobeKey != needsInputModeSwitchKey { model.showsGlobeKey = needsInputModeSwitchKey }
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        model.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        model.textDidChange()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.stop()
        #if DEBUG
        MemoryLog.stop()
        #endif
    }
}

#if DEBUG
/// Logs the keyboard's memory footprint once a second (`log stream` / Console: subsystem `com.davidfromkansas.taki.keyboard`).
/// iOS kills a keyboard that goes over its limit (177 MB on iPhone 17 Pro, iOS 26).
enum MemoryLog {
    private static let logger = Logger(subsystem: "com.davidfromkansas.taki.keyboard", category: "memory")
    nonisolated(unsafe) private static var timer: Timer?

    static func start() {
        timer?.invalidate()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// What the orb is fed while dictating: `level` above 0.3 counts as speaking.
    static func voice(level: Float, spectrum: [Float]) {
        let peak = spectrum.max() ?? 0, mean = spectrum.isEmpty ? 0 : spectrum.reduce(0, +) / Float(spectrum.count)
        logger.notice("TAKIVOICE level \(level, format: .fixed(precision: 2), privacy: .public) bands max \(peak, format: .fixed(precision: 2), privacy: .public) mean \(mean, format: .fixed(precision: 2), privacy: .public) count \(spectrum.count, privacy: .public)")
    }

    static func state(_ change: String) {
        logger.notice("TAKISTATE \(change, privacy: .public)")
    }

    private static func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let used = info.phys_footprint / 1_048_576
        let left = os_proc_available_memory() / 1_048_576
        logger.notice("TAKIMEM footprint \(used, privacy: .public) MB, \(left, privacy: .public) MB left")
    }
}
#endif
