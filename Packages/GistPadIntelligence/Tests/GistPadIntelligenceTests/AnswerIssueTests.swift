import Testing

@testable import GistPadIntelligence

@MainActor
struct AnswerIssueTests {
  private let source =
    "# Incredible\n1. An Example\n\nYou like protagonists who reflect (e.g. An Example)."

  @Test(arguments: [
    ("You wrote “my favorite is An Example”.", NoteAnswerIssue.unverifiedProseQuote),
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
    prose: String, issue: NoteAnswerIssue
  ) async {
    let fixture = NoteModelFixture()
    fixture.answer = [ModelAnswerPart(kind: .prose, text: prose)]
    await #expect(throws: NoteIntelligenceError.invalidAnswer(issue)) {
      try await NoteIntelligenceEngine(backend: fixture).ask(
        request(source, .ask, "What do I like?"))
    }
  }

  @Test func aRunawayStopsAtTheResponseLimitAndIsRetriedOnce() async {
    let fixture = NoteModelFixture()
    fixture.failure = NoteIntelligenceError.responseTooLarge
    await #expect(throws: NoteIntelligenceError.responseTooLarge) {
      try await NoteIntelligenceEngine(backend: fixture).ask(
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
      #expect(NoteAnswerIssue.check(prose, source: source) == nil)
    }
    #expect(
      NoteAnswerIssue.check(
        "The blockID parameter identifies your block.",
        source: "The blockID parameter identifies a block.",
        instruction: "What does blockID do?") == nil)
    #expect(
      NoteAnswerIssue.check(
        "Write {name} where the greeting goes.", source: "Hello, {name}!") == nil)
  }
}
