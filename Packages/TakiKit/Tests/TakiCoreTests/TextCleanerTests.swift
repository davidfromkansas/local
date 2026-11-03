import Testing
@testable import TakiCore

struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test(arguments: [
        ("Um, so I think we should, uh, go.", "So I think we should go."),
        ("Uh I'll be there in ten minutes um.", "I'll be there in ten minutes."),
        ("So, like, I think it's fine.", "So I think it's fine."),
        ("Like, what time is it?", "What time is it?"),
        ("I like pizza a lot.", "I like pizza a lot."),
        ("hmm let me think about it", "Let me think about it."),
    ])
    func `removes filler words`(input: String, expected: String) {
        #expect(cleaner.clean(input) == expected)
    }

    @Test(arguments: [
        ("Let's meet at 5, actually I mean 6.", "Let's meet at 6."),
        ("Let's meet at 5. Actually, I mean 6.", "Let's meet at 6."),
        ("Send it to John, no wait, Mike.", "Send it to Mike."),
        ("I'll bring the red one, actually I mean the blue one.", "I'll bring the blue one."),
        ("Book a table for Tuesday, sorry, Wednesday.", "Book a table for Wednesday."),
        ("Buy milk. Scratch that, buy oat milk.", "Buy oat milk."),
        ("The meeting is at three, actually four.", "The meeting is at four."),
    ])
    func `applies spoken self-corrections`(input: String, expected: String) {
        #expect(cleaner.clean(input) == expected)
    }

    @Test(arguments: [
        "It's good, I mean, really good.",
        "I actually liked the movie.",
        "Sorry I'm late.",
    ])
    func `leaves non-corrections alone`(input: String) {
        #expect(cleaner.clean(input) == input)
    }

    @Test func `collapses stutters but keeps legitimate doubles`() {
        #expect(cleaner.clean("I I think the the plan works.") == "I think the plan works.")
        #expect(cleaner.clean("I know that that is true.") == "I know that that is true.")
        #expect(cleaner.clean("No, no, that's wrong.") == "No, no, that's wrong.")
    }

    @Test func `applies personal dictionary`() {
        let cleaner = TextCleaner(dictionary: [
            DictionaryEntry(term: "FluidAudio"),
            DictionaryEntry(term: "talky", replacement: "Taki"),
            DictionaryEntry(term: "my email", replacement: "david@example.com"),
        ])
        #expect(cleaner.clean("i use fluidaudio in talky") == "I use FluidAudio in Taki.")
        #expect(cleaner.clean("Send it to my email please.") == "Send it to david@example.com please.")
        #expect(cleaner.clean("Talkytalk is unrelated.") == "Talkytalk is unrelated.")
    }

    @Test func `fixes punctuation and capitalization`() {
        #expect(cleaner.clean("hello there , how are you ?") == "Hello there, how are you?")
        #expect(cleaner.clean("i think i'm ready. are you?") == "I think I'm ready. Are you?")
        #expect(cleaner.clean("this is a full sentence") == "This is a full sentence.")
        #expect(cleaner.clean("ok thanks") == "Ok thanks")
        #expect(cleaner.clean("") == "")
        #expect(cleaner.clean("Um.") == "")
    }
}
