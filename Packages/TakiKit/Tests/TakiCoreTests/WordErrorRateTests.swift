import Testing
@testable import TakiCore

struct WordErrorRateTests {
    @Test func `identical text is zero`() {
        #expect(WordErrorRate.compute(reference: "Hello, World!", hypothesis: "hello world") == 0)
    }

    @Test func `number words match digits`() {
        #expect(WordErrorRate.compute(reference: "meet at five", hypothesis: "Meet at 5.") == 0)
    }

    @Test func `counts substitutions deletions and insertions`() {
        #expect(WordErrorRate.compute(reference: "a b c d", hypothesis: "a x c") == 0.5)
        #expect(WordErrorRate.compute(reference: "a b", hypothesis: "a b c d") == 1.0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "") == 0)
    }
}
