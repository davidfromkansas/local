import Foundation

/// A personal-dictionary entry.
/// - `replacement == nil`: a vocabulary word; any casing of `term` becomes exactly `term` ("fluidaudio" → "FluidAudio").
/// - otherwise: a replacement; the spoken `term` is swapped for `replacement` ("talky" → "Taki").
public struct DictionaryEntry: Codable, Sendable, Hashable {
    public var term: String
    public var replacement: String?

    public init(term: String, replacement: String? = nil) {
        self.term = term
        self.replacement = replacement
    }

    public var output: String {
        if let replacement, !replacement.trimmingCharacters(in: .whitespaces).isEmpty { return replacement }
        return term
    }
}
