import Foundation
import Testing

@testable import GistPadIntelligence

struct NoteAnswerIssueTests {
  @Test func inventedQuotesAreRejectedButExactQuotesAndContractionsAreSafe() {
    let source =
      "# Incredible\n1. An Example\n\nYou like protagonists who reflect (e.g. An Example)."
    #expect(
      NoteAnswerIssue.check(
        "An Example. It's #1 in your Incredible tier.", source: source) == nil)
    #expect(
      NoteAnswerIssue.check(
        "You wrote “protagonists who reflect”.", source: source) == nil)
    #expect(
      NoteAnswerIssue.check(
        "You wrote 'protagonists who reflect'.", source: source) == nil)
    #expect(
      NoteAnswerIssue.check(
        "You wrote “my favorite is An Example”.", source: source) == .unverifiedProseQuote)
    #expect(
      NoteAnswerIssue.check(
        "You wrote '(i.e. An Example)'.", source: source) == .unverifiedProseQuote)
    #expect(
      NoteAnswerIssue.check(
        "You wrote 'It's your favorite series'.", source: source) == .unverifiedProseQuote)
    #expect(
      NoteAnswerIssue.check(
        "「my favorite is An Example」と書いています。", source: source) == .unverifiedProseQuote)
  }

  @Test(arguments: [
    "Ranking evidence: firstOrderedItem='An Example'",
    "It appears in block 1.", "It appears in the first block.",
    "Check blockIDs for the reference.", "The second block supports that.",
  ])
  func implementationDetailsNeverBecomeNoteFacts(answer: String) {
    #expect(NoteAnswerIssue.check(answer, source: "A note") != nil)
  }

  @Test func genuineTechnicalContentIsNotMistakenForLeakedRuntimeMetadata() {
    #expect(
      NoteAnswerIssue.check(
        "The blockID parameter identifies your block.",
        source: "The blockID parameter identifies a block.",
        instruction: "What does blockID do?") == nil)
  }

  @Test func thirdPersonAndUnrequestedMarkupAreRejected() {
    #expect(
      NoteAnswerIssue.check(
        "The creator prefers An Example.", source: "A note") == .thirdPerson)
    #expect(
      NoteAnswerIssue.check(
        "The user prefers An Example.", source: "A note") == .thirdPerson)
    #expect(
      NoteAnswerIssue.check(
        "An Example. }</span>", source: "A note") == .markupLeak)
  }

  @Test func factualLengthLimitHasAnExactBoundaryAndDoesNotCountCitations() {
    let sixty = Array(repeating: "word", count: 60).joined(separator: " ")
    #expect(NoteAnswerIssue.check(sixty, source: "", maximumWords: 60) == nil)
    #expect(
      NoteAnswerIssue.check(
        sixty + " extra", source: "", maximumWords: 60) == .answerTooLong)
  }
}
