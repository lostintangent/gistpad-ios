import Testing

@testable import Intelligence

@MainActor
struct AnswerIssueTests {
  private let source =
    "# Incredible\n1. An Example\n\nYou like protagonists who reflect (e.g. An Example)."

  @Test(arguments: [
    ("You wrote “my favorite is An Example”.", AnswerIssue.unverifiedProseQuote),
    ("You wrote '(i.e. An Example)'.", .unverifiedProseQuote),
    ("You wrote 'It's your favorite series'.", .unverifiedProseQuote),
    ("「my favorite is An Example」と書いています。", .unverifiedProseQuote),
    ("The creator prefers An Example.", .thirdPerson),
    ("The user prefers An Example.", .thirdPerson),
    ("An Example. }</span>", .markupLeak),
    ("An Example is your favorite.}", .markupLeak),
    ("Ranking evidence: firstOrderedItem='An Example'", .internalIdentifier),
    ("It appears in block 1.", .internalIdentifier),
    ("It appears in the first block.", .internalIdentifier),
    ("Check blockIDs for the reference.", .internalIdentifier),
    ("The second block supports that.", .internalIdentifier),
  ])
  func theGateRejectsInventedQuotesThirdPersonMarkupAndMetadata(
    prose: String, issue: AnswerIssue
  ) async {
    let fixture = FixtureModel()
    fixture.answer = [ModelAnswerPart(kind: .prose, text: prose)]
    await #expect(throws: IntelligenceError.invalidAnswer(issue)) {
      try await Intelligence(backend: fixture).ask(
        request(source, .ask, "What do I like?"))
    }
  }

  @Test func aRunawayStopsAtTheResponseLimitAndIsRetriedOnce() async {
    let fixture = FixtureModel()
    fixture.failure = IntelligenceError.responseTooLarge
    await #expect(throws: IntelligenceError.responseTooLarge) {
      try await Intelligence(backend: fixture).ask(
        request(source, .ask, "What do I like?"))
    }
    #expect(fixture.passes.map(\.purpose) == [.answer, .answer])
  }

  @Test func theGateAcceptsExactQuotesContractionsTechnicalTextAndCitations() {
    for prose in [
      "An Example. It's #1 in your Incredible tier.",
      "You wrote “protagonists who reflect”.",
      "You wrote 'protagonists who reflect'.",
    ] {
      #expect(AnswerIssue.check(prose, source: source) == nil)
    }
    #expect(
      AnswerIssue.check(
        "The blockID parameter identifies your block.",
        source: "The blockID parameter identifies a block.",
        instruction: "What does blockID do?") == nil)
    #expect(
      AnswerIssue.check(
        "Write {name} where the greeting goes.", source: "Hello, {name}!") == nil)
  }
}
