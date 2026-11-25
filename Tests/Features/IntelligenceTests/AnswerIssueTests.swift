import Testing

@testable import Intelligence

struct AnswerIssueTests {
    private let source =
        "# Incredible\n1. An Example\n\nYou like protagonists who reflect (e.g. An Example)."

    @Test(arguments: [
        ("You wrote “my favorite is An Example”.", Answer.Issue.unverifiedProseQuote),
        ("You wrote '(i.e. An Example)'.", .unverifiedProseQuote),
        ("You wrote 'It's your favorite series'.", .unverifiedProseQuote),
        ("「my favorite is An Example」と書いています。", .unverifiedProseQuote),
        ("The creator prefers An Example.", .thirdPerson),
        ("The user prefers An Example.", .thirdPerson),
        ("An Example. }</span>", .markupLeak),
        ("An Example is your favorite.}", .markupLeak),
        ("Ranking evidence: firstOrderedItem='An Example'", .internalIdentifier),
        ("Your favorite is <title>Example</title>.", .markupLeak),
        ("It appears in block 1.", .internalIdentifier),
        ("It appears in the first block.", .internalIdentifier),
        ("Check blockIDs for the reference.", .internalIdentifier),
        ("The second block supports that.", .internalIdentifier),
    ])
    func theGateRejectsInventedQuotesThirdPersonMarkupAndMetadata(
        prose: String, issue: Answer.Issue
    ) async {
        let fixture = FixtureLanguageModel()
        fixture.answer = Answer.Reply(prose: prose)
        await #expect(throws: IntelligenceError.invalidAnswer(issue)) {
            try await fixture.ask(
                request(source, "What do I like?"))
        }
    }

    @Test func aRunawayStopsAtTheResponseLimitAndIsRetriedOnce() async {
        let fixture = FixtureLanguageModel()
        fixture.failure = IntelligenceError.responseTooLarge
        await #expect(throws: IntelligenceError.responseTooLarge) {
            try await fixture.ask(
                request(source, "What do I like?"))
        }
        #expect(fixture.passes.map(\.purpose) == [.answer, .answer])
    }

    @Test func theGateAcceptsExactQuotesContractionsTechnicalTextAndCitations() {
        for prose in [
            "An Example. It's #1 in your Incredible tier.",
            "You wrote “protagonists who reflect”.",
            "You wrote 'protagonists who reflect'.",
            "You called the top tier \"incredible\".",
            "The ranking evidence puts An Example first.",
        ] {
            #expect(Answer.Reply(prose: prose).issue(in: source) == nil)
        }
        #expect(
            Answer.Reply(prose: "The blockID parameter identifies your block.").issue(
                answering: "What does blockID do?", in: "The blockID parameter identifies a block.")
                == nil)
        #expect(
            Answer.Reply(prose: "Write {name} where the greeting goes.").issue(in: "Hello, {name}!")
                == nil)
        #expect(
            Answer.Reply(prose: "You called it \"real\".").issue(in: "This was realistic.")
                == .unverifiedProseQuote)
    }
}
