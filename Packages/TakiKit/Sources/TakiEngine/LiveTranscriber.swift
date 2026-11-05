import Foundation
import TakiCore

/// Transcribes while the user is still speaking.
///
/// Older speech is cut at a pause (`SpeechSegmenter`), transcribed once and kept. Only the newest stretch
/// (always shorter than one 15 s encoder window) is re-transcribed on each pass, so a pass stays fast however
/// long the dictation runs, and the final pass after the user stops costs the same as a live one.
///
/// Call `transcribe` from one task at a time; `append` is safe at any moment.
public actor LiveTranscriber {
    private let engine: TranscriptionEngine
    /// Audio not committed yet (16 kHz mono).
    private var pending: [Float] = []
    private var committed: [String] = []
    private var lastTail: String?
    private var newSinceLastPass = false

    public init(engine: TranscriptionEngine) {
        self.engine = engine
    }

    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        pending.append(contentsOf: samples)
        newSinceLastPass = true
    }

    /// Raw ASR text for everything heard so far. `final` skips waiting for a pause before cutting.
    public func transcribe(final: Bool = false) async throws -> String {
        var didCommit = false
        if final {
            while pending.count > SpeechSegmenter.hardLimit, let cut = SpeechSegmenter.cutPoint(in: pending) {
                try await commit(upTo: cut)
                didCommit = true
            }
        } else if let cut = SpeechSegmenter.cutPoint(in: pending) {
            try await commit(upTo: cut)
            didCommit = true
        }

        let tail: String
        if !newSinceLastPass, !didCommit, let lastTail {
            tail = lastTail  // nothing new since the last live pass: reuse it
        } else {
            newSinceLastPass = false
            tail = try await engine.transcribe(pending)
            lastTail = tail
        }
        return Self.join(committed + [tail])
    }

    private func commit(upTo cut: Int) async throws {
        let piece = Array(pending[..<cut])
        let text = try await engine.transcribe(piece)
        if !text.isEmpty { committed.append(text) }
        pending.removeFirst(cut)
        lastTail = nil
    }

    static func join(_ pieces: [String]) -> String {
        pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
