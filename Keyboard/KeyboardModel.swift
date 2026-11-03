import Foundation
import Observation
import TakiCore

@Observable
final class KeyboardModel {
    static let barCount = 14

    private(set) var state: KeyboardUIState = .notReady
    private(set) var levels = [Float](repeating: 0, count: KeyboardModel.barCount)
    private(set) var notice: String?
    var hasFullAccess = true
    var showsGlobeKey = true

    @ObservationIgnored var insertText: (String) -> Void = { _ in }
    @ObservationIgnored var deleteBackward: () -> Void = {}
    @ObservationIgnored var contextBeforeInput: () -> String? = { nil }
    @ObservationIgnored var advanceToNextKeyboard: () -> Void = {}

    @ObservationIgnored private let store = SharedStore()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var pendingRequest: UUID?
    /// While waiting for the app to confirm a tap, keep the optimistic state on screen.
    @ObservationIgnored private var optimistic: (state: KeyboardUIState, until: Date)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let startURL = URL(string: "taki://start")!

    func start() {
        refresh()
        deliverResultIfReady()
        listener?.cancel()
        listener = Task { [weak self] in
            for await signal in DarwinNotifications.signals([.stateChanged, .resultReady]) {
                guard let self else { return }
                if signal == .resultReady { deliverResultIfReady() }
                refresh()
            }
        }
        poller?.cancel()
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                tick += 1
                if state == .recording { pushLevel(store?.readLevel() ?? 0) }
                if tick % 15 == 0 { refresh() }
            }
        }
    }

    func stop() {
        listener?.cancel()
        poller?.cancel()
        listener = nil
        poller = nil
    }

    /// Returns true when the caller should open the main app (`taki://start`).
    func micTapped() -> Bool {
        guard hasFullAccess, let store else {
            show("Turn on Allow Full Access for Taki in Settings")
            return false
        }
        switch state {
        case .notReady:
            return true
        case .ready:
            let request = DictationRequest()
            pendingRequest = request.id
            store.write(request)
            levels = [Float](repeating: 0, count: Self.barCount)
            setOptimistic(.recording)
            DarwinNotifications.post(.start)
        case .recording:
            setOptimistic(.processing)
            DarwinNotifications.post(.stop)
        case .processing:
            break
        }
        return false
    }

    var statusText: String {
        if let notice { return notice }
        switch state {
        case .notReady: return hasFullAccess ? "Tap the mic to start Taki" : "Allow Full Access to use Taki"
        case .ready: return "Tap to dictate"
        case .recording: return "Listening… tap to finish"
        case .processing: return "Writing it down…"
        }
    }

    private func setOptimistic(_ next: KeyboardUIState) {
        optimistic = (next, .now.addingTimeInterval(1.5))
        state = next
    }

    private func refresh() {
        let snapshot = store?.readSnapshot()
        let actual = KeyboardUIState(snapshot: snapshot)
        if let optimistic {
            if actual == optimistic.state || Date.now >= optimistic.until || actual == .ready && optimistic.state == .processing && pendingRequest == nil {
                self.optimistic = nil
            } else {
                return
            }
        }
        if state != actual { state = actual }
        if let error = snapshot?.errorMessage, !error.isEmpty, actual == .ready {
            show("Something went wrong — try again")
        }
    }

    private func deliverResultIfReady() {
        guard let pending = pendingRequest, let result = store?.readResult(), result.requestID == pending else { return }
        pendingRequest = nil
        optimistic = nil
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show("Didn't catch that — try again")
            return
        }
        insertText(Self.spaced(text, after: contextBeforeInput()))
    }

    /// Adds a leading space when dictating right after a word.
    static func spaced(_ text: String, after context: String?) -> String {
        guard let last = context?.last, !last.isWhitespace, !"([{\"'“‘/".contains(last) else { return text }
        return " " + text
    }

    private func pushLevel(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
