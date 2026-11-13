import Testing
@testable import TakiCore

struct PolishGuardTests {
    @Test func `accepts a light edit`() {
        #expect(PolishGuard.accepts(
            "Let's meet at 3 tomorrow to go over the budget.",
            for: "lets meet at 3 tomorrow to go over the budget"))
    }

    @Test func `rejects an answer to a dictated question`() {
        #expect(!PolishGuard.accepts(
            "It's usually around 3 PM in Tokyo when it's midnight in London.",
            for: "What time is it in Tokyo when it's midnight in London?"))
        #expect(!PolishGuard.accepts("Paris is the capital of France.", for: "what is the capital of France"))
    }

    @Test func `keeps a question a question`() {
        #expect(PolishGuard.accepts("Can you send me the report by Friday?", for: "can you send me the report by friday"))
        #expect(!PolishGuard.accepts("You can send me the report by Friday.", for: "can you send me the report by friday"))
    }

    @Test func `rejects assistant chatter and rewrites`() {
        #expect(!PolishGuard.accepts("Sure! Here's the edited text: buy milk and eggs.", for: "buy milk and eggs"))
        #expect(!PolishGuard.accepts("Purchase dairy and poultry products.", for: "buy milk and eggs"))
        #expect(!PolishGuard.accepts("Buy milk.\nBuy eggs.", for: "buy milk buy eggs"))
        #expect(!PolishGuard.accepts("", for: "buy milk"))
    }
}
