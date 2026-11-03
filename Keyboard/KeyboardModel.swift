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
    var layer: KeyLayer = .letters
    private(set) var shift: ShiftState = .on

    enum KeyLayer { case letters, numbers, symbols }
    enum ShiftState { case off, on, locked }

    @ObservationIgnored var insertText: (String) -> Void = { _ in }
    @ObservationIgnored var deleteBackward: () -> Void = {}
    @ObservationIgnored var contextBeforeInput: () -> String? = { nil }
    @ObservationIgnored var advanceToNextKeyboard: () -> Void = {}
    /// Opens a URL in another app. Returns false when the system refused.
    @ObservationIgnored var openURL: (URL) -> Bool = { _ in false }

    @ObservationIgnored private let store = SharedStore()
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var pendingRequest: UUID?
    /// While waiting for the app to confirm a tap, keep the optimistic state on screen.
    @ObservationIgnored private var optimistic: (state: KeyboardUIState, until: Date)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var lastShiftTap = Date.distantPast

    static let startURL = URL(string: "taki://start")!

    func start() {
        updateAutoShift()
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

    func micTapped() {
        guard hasFullAccess, let store else {
            show("Turn on Allow Full Access for Taki in Settings")
            return
        }
        switch state {
        case .notReady:
            if !openURL(Self.startURL) { show("Open the Taki app to start") }
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
        updateAutoShift()
    }

    // MARK: Typing

    func type(_ key: String) {
        insertText(layer == .letters && shift != .off ? key.uppercased() : key)
        if shift == .on { shift = .off }
        if key == "'" && layer != .letters { layer = .letters }
    }

    func space() {
        let context = contextBeforeInput() ?? ""
        if context.hasSuffix(" "), let previous = context.dropLast().last, previous.isLetter || previous.isNumber {
            deleteBackward()
            insertText(". ")
        } else {
            insertText(" ")
        }
        if layer != .letters { layer = .letters }
        updateAutoShift()
    }

    func returnKey() {
        insertText("\n")
        updateAutoShift()
    }

    func delete() {
        deleteBackward()
        updateAutoShift()
    }

    /// Single tap toggles shift; a quick double tap locks caps.
    func shiftTapped() {
        let now = Date.now
        if shift == .on && now.timeIntervalSince(lastShiftTap) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .on : .off
        }
        lastShiftTap = now
    }

    func textDidChange() {
        updateAutoShift()
    }

    private func updateAutoShift() {
        guard shift != .locked else { return }
        shift = Self.shouldCapitalize(after: contextBeforeInput()) ? .on : .off
    }

    /// Sentence start: empty field, new line, or after ". " / "? " / "! ".
    static func shouldCapitalize(after context: String?) -> Bool {
        guard let context, let last = context.last else { return true }
        if last.isNewline { return true }
        guard last.isWhitespace else { return false }
        guard let mark = context.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?".contains(mark) || mark.isNewline
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
