#if DEBUG && canImport(UIKit)
  import Testing
  @testable import GistPadEditor

  @MainActor
  struct IntelligenceEvaluationTests {
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
