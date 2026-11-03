import Foundation
import SwiftData
import TakiCore
import TakiEngine

@Model
final class TranscriptRecord {
    var id = UUID()
    var createdAt = Date.now
    var text = ""
    var rawText = ""
    var audioSeconds = 0.0
    var processingSeconds = 0.0

    init(output: DictationOutput, createdAt: Date = .now) {
        self.createdAt = createdAt
        text = output.text
        rawText = output.rawText
        audioSeconds = output.audioSeconds
        processingSeconds = output.asrSeconds + output.cleanupSeconds
    }

    init(text: String, createdAt: Date = .now) {
        self.text = text
        rawText = text
        self.createdAt = createdAt
    }
}

@Model
final class DictionaryWord {
    var term = ""
    /// Empty means "always spell it like `term`".
    var replacement = ""
    var createdAt = Date.now

    init(term: String, replacement: String = "") {
        self.term = term
        self.replacement = replacement
    }

    var entry: DictionaryEntry {
        DictionaryEntry(term: term, replacement: replacement.isEmpty ? nil : replacement)
    }
}
