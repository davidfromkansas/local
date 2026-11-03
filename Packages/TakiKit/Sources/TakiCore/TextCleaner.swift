import Foundation

/// Deterministic "light edit" pass: fillers, spoken self-corrections, stutters, personal dictionary,
/// then punctuation/capitalization. Never rewrites wording beyond those rules.
public struct TextCleaner: Sendable {
    public var dictionary: [DictionaryEntry]

    public init(dictionary: [DictionaryEntry] = []) {
        self.dictionary = dictionary
    }

    public func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words = Self.removeFillers(words)
        words = Self.applySelfCorrections(words)
        words = Self.collapseRepeats(words)
        var output = words.joined(separator: " ")
        output = Self.applyDictionary(dictionary, to: output)
        return Self.fixPunctuationAndCase(output)
    }

    // MARK: - Fillers

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm"]

    static func removeFillers(_ words: [String]) -> [String] {
        var out: [String] = []
        for word in words {
            let core = bare(word)
            let isLikeFiller = core == "like" && word.hasSuffix(",")
                && (out.last.map { $0.hasSuffix(",") || endsSentence($0) } ?? true)
            guard fillers.contains(core) || isLikeFiller else {
                out.append(word)
                continue
            }
            // Keep sentence-ending punctuation the filler was carrying.
            if let mark = word.last, ".!?".contains(mark), let last = out.last, !endsSentence(last) {
                out[out.count - 1] = last.trimmingTrailingPunctuation() + String(mark)
            } else if word.hasSuffix(","), let last = out.last, last.hasSuffix(",") {
                // "we should, uh, go" → "we should go"
                out[out.count - 1] = String(last.dropLast())
            }
        }
        return out
    }

    // MARK: - Self-corrections ("at 5, actually I mean 6" → "at 6")

    private struct Marker {
        let words: [String]
        /// Strong markers always correct; weak ones need an anchor/number match to fire.
        let strong: Bool
        var scratch: Bool = false
    }

    private static let markers: [Marker] = [
        Marker(words: ["scratch", "that"], strong: true, scratch: true),
        Marker(words: ["actually", "i", "mean"], strong: true),
        Marker(words: ["actually", "i", "meant"], strong: true),
        Marker(words: ["no", "i", "mean"], strong: true),
        Marker(words: ["no", "i", "meant"], strong: true),
        Marker(words: ["sorry", "i", "mean"], strong: true),
        Marker(words: ["sorry", "i", "meant"], strong: true),
        Marker(words: ["no", "wait"], strong: true),
        Marker(words: ["wait", "no"], strong: true),
        Marker(words: ["or", "rather"], strong: true),
        Marker(words: ["i", "meant"], strong: true),
        Marker(words: ["i", "mean"], strong: false),
        Marker(words: ["actually"], strong: false),
        Marker(words: ["sorry"], strong: false),
    ]

    static func applySelfCorrections(_ input: [String]) -> [String] {
        var words = input
        var searchFrom = 0
        while let (markerIndex, marker) = findMarker(in: words, from: searchFrom) {
            let yStart = markerIndex + marker.words.count
            // A marker must follow a clause break ("…5, actually…" / "…5. Actually…").
            guard markerIndex > 0, hasClauseBreak(words[markerIndex - 1]) || marker.strong else {
                searchFrom = yStart
                continue
            }
            // A one-word marker set off by commas ("Tuesday, sorry, Wednesday") is a clear correction.
            let isStrong = marker.strong
                || (marker.words.count == 1 && marker.words != ["i"] && words[yStart - 1].hasSuffix(","))
            let start = sentenceStart(in: words, containing: markerIndex - 1)
            var yEnd = yStart
            while yEnd < words.count {
                yEnd += 1
                if endsSentence(words[yEnd - 1]) { break }
            }
            guard yEnd > yStart else { break }
            var correction = Array(words[yStart..<yEnd])

            if marker.scratch {
                words.removeSubrange(start..<yStart)
                searchFrom = start
                continue
            }

            guard let replaceAt = replacementIndex(
                for: correction, in: words, range: start..<markerIndex, strong: isStrong
            ) else {
                searchFrom = yStart
                continue
            }
            if replaceAt == start, words[start].first?.isUppercase == true {
                correction[0] = correction[0].capitalizingFirst()
            }
            words.replaceSubrange(replaceAt..<yEnd, with: correction)
            searchFrom = replaceAt + correction.count
        }
        return words
    }

    private static func findMarker(in words: [String], from: Int) -> (Int, Marker)? {
        guard from < words.count else { return nil }
        for index in from..<words.count {
            for marker in markers where index + marker.words.count <= words.count {
                let slice = words[index..<(index + marker.words.count)].map(bare)
                guard slice == marker.words else { continue }
                // Interior punctuation ("no. Wait") breaks multi-word markers apart, except a trailing comma.
                let interior = words[index..<(index + marker.words.count - 1)]
                if interior.contains(where: { $0.last.map { ".!?".contains($0) } ?? false }) { continue }
                return (index, marker)
            }
        }
        return nil
    }

    private static func replacementIndex(
        for correction: [String], in words: [String], range: Range<Int>, strong: Bool
    ) -> Int? {
        guard !range.isEmpty, let head = correction.first.map(bare), !head.isEmpty else { return nil }
        // 1. Anchor: the correction restates an earlier word ("the red one, I mean the blue one").
        if let anchor = range.reversed().first(where: { bare(words[$0]) == head }) {
            return anchor
        }
        // 2. Numbers replace the last number ("at 5, actually 6").
        if isNumber(head), let number = range.reversed().first(where: { isNumber(bare(words[$0])) }) {
            return number
        }
        // 3. Strong markers replace the same number of trailing words ("to John, no wait, Mike").
        guard strong else { return nil }
        return max(range.lowerBound, range.upperBound - correction.count)
    }

    private static func sentenceStart(in words: [String], containing index: Int) -> Int {
        var start = index
        while start > 0, !endsSentence(words[start - 1]) { start -= 1 }
        return start
    }

    // MARK: - Stutters ("the the" → "the")

    static let legitimateDoubles: Set<String> = ["that", "had", "is", "do"]

    static func collapseRepeats(_ words: [String]) -> [String] {
        var out: [String] = []
        for word in words {
            if let last = out.last, last == last.trimmingTrailingPunctuation(),
               bare(last) == bare(word), !bare(word).isEmpty,
               bare(word).allSatisfy(\.isLetter), !legitimateDoubles.contains(bare(word)) {
                let keepCase = last.first?.isUppercase == true
                out[out.count - 1] = keepCase ? word.capitalizingFirst() : word
                continue
            }
            out.append(word)
        }
        return out
    }

    // MARK: - Dictionary

    public static func applyDictionary(_ entries: [DictionaryEntry], to text: String) -> String {
        var output = text
        let sorted = entries
            .filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.term.count > $1.term.count }
        for entry in sorted {
            let term = NSRegularExpression.escapedPattern(for: entry.term.trimmingCharacters(in: .whitespaces))
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\w])\(term)(?![\\w])", options: [.caseInsensitive]) else {
                continue
            }
            let template = NSRegularExpression.escapedTemplate(for: entry.output)
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output), withTemplate: template
            )
        }
        return output
    }

    // MARK: - Punctuation & capitalization

    static func fixPunctuationAndCase(_ text: String) -> String {
        var s = text
        s = s.replacing(/\s+([,.!?;:])/, with: { $0.output.1 })
        s = s.replacing(/,(\s*[,.!?])/, with: { $0.output.1.trimmingCharacters(in: .whitespaces) })
        s = s.replacing(/([.!?])\s*\./, with: { $0.output.1 })
        s = s.replacing(/^[\s,.;:]+/, with: "")
        s = s.replacing(/\s{2,}/, with: " ")
        s = replacingPattern(#"(?<![\w'])i(?=('[a-z]+)?(?![\w']))"#, in: s, with: "I")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize the start of each sentence.
        var result = ""
        var capitalizeNext = true
        var afterTerminal = false
        for character in s {
            if capitalizeNext, character.isLetter {
                result.append(contentsOf: character.uppercased())
                capitalizeNext = false
                afterTerminal = false
                continue
            }
            result.append(character)
            if ".!?".contains(character) {
                afterTerminal = true
            } else if character.isWhitespace {
                if afterTerminal { capitalizeNext = true }
            } else if !"\"'(".contains(character) {
                // "example.com" — a period not followed by a space doesn't end a sentence.
                capitalizeNext = false
                afterTerminal = false
            }
        }

        let wordCount = result.split(whereSeparator: \.isWhitespace).count
        if wordCount >= 4, let last = result.last, !".!?…:;\"')".contains(last) {
            result.append(".")
        }
        return result
    }

    // MARK: - Helpers

    static func replacingPattern(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?".contains(last)
    }

    static func hasClauseBreak(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",.!?;:—-".contains(last)
    }

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred", "noon", "midnight",
    ]

    static func isNumber(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || numberWords.contains(word)
    }
}

extension String {
    func trimmingTrailingPunctuation() -> String {
        var s = self
        while let last = s.last, last.isPunctuation { s.removeLast() }
        return s
    }

    func capitalizingFirst() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
