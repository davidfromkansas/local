import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
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

        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.isMultipleTouchEnabled = true
        host.sizingOptions = []
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
    }
}
