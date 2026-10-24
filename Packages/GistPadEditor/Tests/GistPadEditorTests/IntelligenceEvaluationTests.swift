#if DEBUG && canImport(UIKit)
  import Foundation
  import Testing
  @testable import GistPadEditor

  @MainActor
  struct IntelligenceEvaluationTests {
    @Test func latencyTableIncludesRetryResponsesButNeverInventsATimeForFailureOrOldData() throws {
      let results = try JSONDecoder().decode(
        [NoteEvaluationResult].self,
        from: Data(
          """
          [
            {"caseID":"timing","repeatIndex":1,
             "requestID":"00000000-0000-0000-0000-000000000001",
             "passed":true,"elapsedSeconds":100,"timeToVisibleAnswerSeconds":1,
             "answerCompletionSeconds":2,"qualityRetryCount":0},
            {"caseID":"timing","repeatIndex":2,
             "requestID":"00000000-0000-0000-0000-000000000002",
             "passed":true,"elapsedSeconds":100,"timeToVisibleAnswerSeconds":9,
             "answerCompletionSeconds":10,"qualityRetryCount":1},
            {"caseID":"timing","repeatIndex":3,
             "requestID":"00000000-0000-0000-0000-000000000003",
             "passed":false,"elapsedSeconds":100,"qualityRetryCount":1,"errorCode":"invalidAnswer"},
            {"caseID":"legacy","repeatIndex":1,
             "requestID":"00000000-0000-0000-0000-000000000004",
             "passed":true,"elapsedSeconds":100}
          ]
          """.utf8))
      let table = NoteIntelligenceEvaluation.table(results)
      #expect(table.contains("5.00 / 8.20 s (2)"))
      #expect(table.contains("6.00 / 9.20 s (2)"))
      #expect(table.contains("2/3; 9.00 / 9.00 s (1)"))
      #expect(table.contains("| legacy | 1/1 | - | - | - |"))
    }

    @Test func latencyPercentilesUseEveryMeasuredResponseAndExactInterpolation() {
      let summary = NoteIntelligenceEvaluation.latencySummary([10, 1, 9, 2, 8, 3, 7, 4, 6, 5])
      #expect(summary?.p50 == 5.5)
      #expect(summary?.p90 == 9.1)
      #expect(NoteIntelligenceEvaluation.latencySummary([]) == nil)
      #expect(NoteIntelligenceEvaluation.latencySummary([4.25])?.p90 == 4.25)
    }

    @Test func everyAskCaseUsesQualityGuardsAndOnlyFactualCasesUseTheWordCap() {
      let summary = NoteEvaluationCase(
        id: "summary", action: "ask", source: "1. An Example", prompt: "Summarize")
      let factual = NoteEvaluationCase(
        id: "factual", action: "ask", source: "1. An Example", prompt: "What comes first?",
        maximumAnswerWords: 60)
      #expect(
        NoteIntelligenceEvaluation.answerFailure(
          "The user likes An Example.", for: summary) == "thirdPerson")
      #expect(
        NoteIntelligenceEvaluation.answerFailure(
          "An Example is in block 1.", for: summary) == "internalIdentifier")
      #expect(
        NoteIntelligenceEvaluation.answerFailure(
          "You wrote “my favorite”.", for: summary) == "unverifiedProseQuote")
      #expect(
        NoteIntelligenceEvaluation.answerFailure(
          "An Example. }</span>", for: summary) == "markupLeak")
      let long = Array(repeating: "word", count: 61).joined(separator: " ")
      #expect(NoteIntelligenceEvaluation.answerFailure(long, for: factual) == "answerTooLong")
      #expect(NoteIntelligenceEvaluation.answerFailure(long, for: summary) == nil)
    }

    @Test func favoriteGradingRequiresProseConclusionAndRejectsCompetingFavorites() {
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "The Glass Orchard is your likely favorite, based on its number-one ranking.",
          expected: "The Glass Orchard", alternatives: ["City of Paper"]) == nil)
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "The note is a list of books.", expected: "The Glass Orchard",
          alternatives: []) == "favoriteNameMissing")
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "You have finished The Glass Orchard.", expected: "The Glass Orchard",
          alternatives: []) == "favoriteNotIdentified")
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "I don't know your favorite. The Glass Orchard is listed.",
          expected: "The Glass Orchard", alternatives: []) == "favoriteNotIdentified")
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "The Glass Orchard is not your favorite.", expected: "The Glass Orchard",
          alternatives: []) == "favoriteNotIdentified")
      #expect(
        NoteIntelligenceEvaluation.favoriteFailure(
          answer: "Your favorites are The Glass Orchard and City of Paper.",
          expected: "The Glass Orchard", alternatives: ["City of Paper"]) == "competingFavorite")
    }
  }
#endif
