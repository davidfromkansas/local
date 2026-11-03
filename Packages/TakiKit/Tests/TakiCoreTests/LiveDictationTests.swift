import Testing
@testable import TakiCore

struct TextEditTests {
    @Test func `growing text only types the new words`() {
        #expect(TextEdit.from("Hello", to: "Hello there") == TextEdit(deleteCount: 0, insert: " there"))
    }

    @Test func `changed ending is deleted and retyped`() {
        #expect(TextEdit.from("I want to", to: "I went to the") == TextEdit(deleteCount: 7, insert: "ent to the"))
    }

    @Test func `same text does nothing`() {
        #expect(TextEdit.from("Same.", to: "Same.") == TextEdit(deleteCount: 0, insert: ""))
    }

    @Test func `clearing deletes everything`() {
        #expect(TextEdit.from(" um", to: "") == TextEdit(deleteCount: 3, insert: ""))
    }

    @Test func `field check sees edits by the user`() {
        #expect(TextEdit.field("Note: hello there", endsWith: " hello there"))
        #expect(!TextEdit.field("Note: hello there!", endsWith: " hello there"))
        // iOS cut the context short: a matching tail still counts, an empty one doesn't.
        #expect(TextEdit.field("there", endsWith: " hello there"))
        #expect(!TextEdit.field("", endsWith: " hello"))
        #expect(TextEdit.field("", endsWith: ""))
    }
}

struct SpeechSegmenterTests {
    static let rate = SpeechSegmenter.sampleRate

    /// Loud "speech" with silent gaps at the given second ranges.
    static func audio(seconds: Double, gaps: [ClosedRange<Double>] = []) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            if gaps.contains(where: { $0.contains(t) }) { return 0 }
            return i % 2 == 0 ? 0.2 : -0.2
        }
    }

    @Test func `short audio is never cut`() {
        #expect(SpeechSegmenter.cutPoint(in: Self.audio(seconds: 7, gaps: [5...5.5])) == nil)
    }

    @Test func `cuts inside a pause`() throws {
        let cut = try #require(SpeechSegmenter.cutPoint(in: Self.audio(seconds: 10, gaps: [6...6.6])))
        let seconds = Double(cut) / Double(Self.rate)
        #expect((6...6.6).contains(seconds))
    }

    @Test func `waits when there is no pause yet`() {
        #expect(SpeechSegmenter.cutPoint(in: Self.audio(seconds: 10)) == nil)
    }

    @Test func `always cuts past the hard limit`() throws {
        let cut = try #require(SpeechSegmenter.cutPoint(in: Self.audio(seconds: 14.5)))
        #expect(cut > 4 * Self.rate && cut < 14 * Self.rate)
    }

    @Test func `ignores pauses too close to the start`() {
        #expect(SpeechSegmenter.cutPoint(in: Self.audio(seconds: 9, gaps: [1...2])) == nil)
    }
}
