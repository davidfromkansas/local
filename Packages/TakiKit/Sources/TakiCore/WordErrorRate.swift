import Foundation

/// Word error rate = (substitutions + deletions + insertions) / reference words, after normalization.
public enum WordErrorRate {
    public static func compute(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirty": "30", "fifteen": "15", "twenty": "20", "forty": "40", "fifty": "50",
    ]

    /// Lowercase, strip punctuation (keep apostrophes), split "6:30" / "$40", map small number words to digits.
    public static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacing(/[^a-z0-9' ]+/, with: " ")
        return lowered.split(separator: " ").map { word in
            let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            return numberWords[w] ?? w
        }.filter { !$0.isEmpty }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}
