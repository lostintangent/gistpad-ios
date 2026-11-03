import Testing

@testable import IntelligenceEval

@MainActor
struct FavoriteTests {
  @Test func anUnrelatedWordDoesNotBecomeACompetingTitle() {
    let answer = "Your favorite is Vagabond, for its realistic struggles."
    #expect(
      Evaluator.favoriteFailure(
        answer: answer, expected: "Vagabond", alternatives: ["Real"]) == nil)
  }

  @Test func anActualAlternativeInTheFavoriteClaimStillFails() {
    #expect(
      Evaluator.favoriteFailure(
        answer: "Your favorite is Real, or possibly Vagabond.",
        expected: "Vagabond", alternatives: ["Real"]) == "competingFavorite")
    #expect(
      Evaluator.favoriteFailure(
        answer: "Vagabond is your favorite, not Real.",
        expected: "Vagabond", alternatives: ["Real"]) == nil)
  }

  @Test func aTopMangaAnswerIdentifiesTheAskedFavorite() {
    #expect(
      Evaluator.favoriteFailure(
        answer: "Your top manga is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "The ranking-based inference identifies the top-rated series as Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "#1 in the highest-rated completed section is Vagabond. This follows from your ranking.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "#1 in the ranked completed series is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "#1 in the \"incredible\" tier is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "#1 in the lower tier is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) != nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "The top choice is a single series. This series is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) == nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "Your top choice is Billy Bat. This series is Vagabond.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) != nil)
    #expect(
      Evaluator.favoriteFailure(
        answer: "Your favorite is Billy Bat. Vagabond appears elsewhere.",
        expected: "Vagabond", alternatives: ["Billy Bat"]) != nil)
  }

  @Test func aNameOnlyAnswerMustActuallyNameTheCorrectItem() {
    let question = EvalCase(
      id: "rank", action: "ask", source: "1. Cedar\n2. Night Orchard\n4. Lantern Makers",
      prompt: "Which ranks higher, Night Orchard or Lantern Makers? Name only the title.",
      exactAnswers: ["Night Orchard"])
    #expect(Evaluator.answerFailure("Night Orchard.", for: question) == nil)
    #expect(
      Evaluator.answerFailure("Cedar ranks higher than Night Orchard.", for: question)
        == "answerNotExact")
  }

  @Test func mentioningTheCorrectCountIncidentallyDoesNotPass() {
    let question = EvalCase(
      id: "count", action: "ask", source: "Three issues remain open.",
      prompt: "How many issues are still open?",
      mentions: [
        ["three open", "3 open", "three issues", "3 issues", "three remain", "3 remain"]
      ])
    #expect(
      Evaluator.answerFailure("There are five open issues and three others.", for: question)
        == "factMissing")
    #expect(Evaluator.answerFailure("Three issues remain open.", for: question) == nil)
  }

  @Test func namingTheInspectorWhileAssigningTheUserStillFails() {
    let question = EvalCase(
      id: "inspector", action: "ask", source: "Noor will inspect the loose floorboard.",
      prompt: "Who inspects the floorboard?", mentions: [["Noor"]],
      avoids: ["You are the one inspecting", "You inspect"])
    #expect(
      Evaluator.answerFailure(
        "You are the one inspecting the floorboard; Noor is the carpenter.", for: question)
        == "ungroundedFact")
    #expect(Evaluator.answerFailure("Noor will inspect the floorboard.", for: question) == nil)
  }
}
