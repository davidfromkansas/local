import Foundation

/// Decides whether a language model's "cleaned" text is still the user's own words.
///
/// Cleanup models sometimes treat a dictated question or request as a prompt and answer it
/// ("what time is it in Tokyo" → "It's 3 PM in Tokyo."). Every check here is cheap and local; when
/// any fails the caller keeps the rules-cleaned text.
public enum PolishGuard {
    /// Output length (characters) relative to the input.
    public static let lengthRatio: ClosedRange<Double> = 0.6...1.25
    /// Share of the input's words that must survive.
    public static let minKeptWords = 0.7
    /// Share of the output's words that may be new (fixed slips, "gonna" → "going to").
    public static let maxNewWords = 0.25

    private static let assistantOpeners = [
        "sure", "certainly", "of course", "here is", "here's", "here are", "i'd be happy", "i can",
        "i cannot", "i can't", "as an ai", "the edited text", "edited text", "corrected text", "answer:",
        "okay, here", "ok, here", "great question", "absolutely",
    ]

    public static func accepts(_ output: String, for input: String) -> Bool {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, !input.isEmpty else { return false }

        let ratio = Double(output.count) / Double(input.count)
        guard lengthRatio.contains(ratio) else { return false }

        let lowerOut = output.lowercased(), lowerIn = input.lowercased()
        for opener in assistantOpeners where lowerOut.hasPrefix(opener) && !lowerIn.hasPrefix(opener) {
            return false
        }
        // One paragraph in, one paragraph out: answers tend to add lists and line breaks.
        if output.contains("\n") && !input.contains("\n") { return false }

        let inWords = WordErrorRate.normalize(input), outWords = WordErrorRate.normalize(output)
        guard !inWords.isEmpty, !outWords.isEmpty else { return false }
        let inBag = Set(inWords), outBag = Set(outWords)
        let kept = Double(inWords.filter(outBag.contains).count) / Double(inWords.count)
        let added = Double(outWords.filter { !inBag.contains($0) }.count) / Double(outWords.count)
        guard kept >= minKeptWords, added <= maxNewWords else { return false }

        // A dictated question must stay a question.
        if isQuestion(input) && !output.contains("?") && !startsLikeQuestion(output) { return false }
        return true
    }

    private static let questionStarters: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which", "can", "could", "would",
        "should", "will", "do", "does", "did", "is", "are", "was", "were", "have", "has", "shall", "may",
    ]

    static func isQuestion(_ text: String) -> Bool {
        text.contains("?") || startsLikeQuestion(text)
    }

    private static func startsLikeQuestion(_ text: String) -> Bool {
        guard let first = WordErrorRate.normalize(text).first else { return false }
        return questionStarters.contains(first)
    }
}
