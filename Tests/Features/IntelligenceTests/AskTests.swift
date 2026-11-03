import Foundation
import Testing

@testable import Intelligence

@MainActor
struct AskTests {
  private let manga = """
    # Manga Reading List

    ### Currently reading
    1. Frieren, volume 8
    2. Witch Hat Atelier, volume 4

    ### Next
    1. Yotsuba&!, volume 1
    2. A short series for the weekend
    """

  @Test func askAnswersFromTheWholeFileShortOrLong() async throws {
    let fixture = FixtureModel()
    fixture.answer = [
      ModelAnswerPart(kind: .prose, text: "You are reading two series and have two next reads."),
      ModelAnswerPart(kind: .quote, text: "1. Frieren, volume 8"),
    ]
    let short = request(manga, .ask, "Summarize my reading list")
    let answer = try await Intelligence(backend: fixture).ask(short)
    #expect(answer.count == 2)
    #expect(fixture.passes.map(\.source) == [manga])
    #expect(fixture.passes.map(\.requestID) == [short.id])

    let long = String(repeating: "A background paragraph.\n\n", count: 100) + "needle"
    let reader = FixtureModel()
    reader.contextSize = 1_536
    reader.excerpts = { $0.source.contains("needle") ? ["needle"] : [] }
    reader.answer = [ModelAnswerPart(kind: .quote, text: "needle")]
    let found = try await Intelligence(backend: reader).ask(
      request(long, .ask, "Find needle"))
    let reads = reader.passes.filter { $0.purpose == .extract }
    #expect(reads.map(\.source).joined().utf8.elementsEqual(long.utf8))
    #expect(reader.passes.filter { $0.purpose == .answer }.map(\.evidenceBlocks) == [["needle"]])
    #expect(found.count == 1)
  }

  @Test func aCitationCarriesTheExactPassageForShowInFile() async throws {
    let fixture = FixtureModel()
    fixture.answer = [ModelAnswerPart(kind: .quote, text: "👩🏽‍💻")]
    let answer = try await Intelligence(backend: fixture).ask(
      request("Hello 👩🏽‍💻\r\n", .ask, "Quote the emoji"))
    #expect(
      answer == [.quotation("👩🏽‍💻", ranges: [NSRange(location: 6, length: "👩🏽‍💻".utf16.count)])])

    let original = "# One\r\n\r\nFirst 👩🏽‍💻\r\n\r\n# Two\n\nSecond cafe\u{301}\n"
    let blocks = SourceBlock.blocks(in: original)
    #expect(blocks.map(\.text).joined().utf8.elementsEqual(original.utf8))
    let parts = try OnDeviceModel.parseAnswer(
      "The second section answers.\n[Sources: 2]", blocks: blocks)
    #expect(parts.last == ModelAnswerPart(kind: .quote, text: blocks[1].text))
    let plain = try OnDeviceModel.parseAnswer(
      "The second section answers.\nSources: 2", blocks: blocks)
    #expect(plain == parts)
    #expect(
      try OnDeviceModel.parseAnswer(
        "The second section answers. [Sources: 2]", blocks: blocks) == parts)
    #expect(OnDeviceModel.visibleAnswer("The answer.\nSources: 2") == "The answer.")
    #expect(OnDeviceModel.visibleAnswer("The answer.\n[Sources:") == "The answer.")
    #expect(OnDeviceModel.visibleAnswer("The answer.\nSou") == "The answer.")
    #expect(OnDeviceModel.visibleAnswer("The answer. [Sou") == "The answer.")
    #expect(OnDeviceModel.visibleAnswer("The answer. [Sources: 2]") == "The answer.")
    #expect(throws: IntelligenceError.unverifiedQuotation) {
      try OnDeviceModel.parseAnswer("An answer\n[Sources: 99]", blocks: blocks)
    }
    #expect(throws: IntelligenceError.invalidResponse) {
      try OnDeviceModel.parseAnswer("An answer\n[Sources: nope]", blocks: blocks)
    }
    #expect(throws: IntelligenceError.invalidResponse) {
      try OnDeviceModel.parseAnswer("An answer\nSources: nope", blocks: blocks)
    }
    #expect(throws: IntelligenceError.invalidResponse) {
      try OnDeviceModel.parseAnswer("An answer [Sources: 2", blocks: blocks)
    }
  }

  @Test func answerStreamsProseBeforeVerifiedCitations() async throws {
    let fixture = FixtureModel()
    fixture.partialAnswers = ["Your", "Your note says"]
    fixture.answer = [
      ModelAnswerPart(kind: .prose, text: "Your note says the route is south."),
      ModelAnswerPart(kind: .quote, text: "The route is south."),
    ]
    var updates: [String] = []
    let response = try await Intelligence(backend: fixture).ask(
      request("The route is south.", .ask, "Which route?"),
      onPartialAnswer: { updates.append($0) })
    #expect(updates == ["", "Your", "Your note says"])
    #expect(response.count == 2)
    #expect(
      response.last
        == .quotation(
          "The route is south.",
          ranges: [NSRange(location: 0, length: "The route is south.".utf16.count)]))
  }

  @Test func anUnverifiedSourceIDGetsOneCleanRetry() async throws {
    let fixture = FixtureModel()
    fixture.nextFailure = IntelligenceError.unverifiedQuotation
    fixture.answer = [ModelAnswerPart(kind: .prose, text: "The route is south.")]
    var updates: [String] = []
    let answer = try await Intelligence(backend: fixture).ask(
      request("The route is south.", .ask, "Which route?"),
      onPartialAnswer: { updates.append($0) })
    #expect(fixture.passes.map(\.purpose) == [.answer, .answer])
    #expect(updates == ["", "", "The route is south."])
    #expect(answer == [.prose("The route is south.")])
  }

  @Test func askNeverReadsOrCitesFrontMatter() async throws {
    let prefix = "---\r\nprivate: A hidden fact 👩🏽‍💻\r\n---\r\n\r\n"
    let body = "# Content\r\n\r\nA visible fact 👩🏽‍💻.\r\n"
    let fixture = FixtureModel()
    fixture.answer = [ModelAnswerPart(kind: .quote, text: "A visible fact 👩🏽‍💻.")]
    let input = request(prefix + body, .ask, "What is visible?")
    let answer = try await Intelligence(backend: fixture).ask(input)
    #expect(fixture.passes.map(\.source) == [body])
    #expect(
      answer == [
        .quotation(
          "A visible fact 👩🏽‍💻.",
          ranges: [
            NSRange(
              location: prefix.utf16.count + "# Content\r\n\r\n".utf16.count,
              length: "A visible fact 👩🏽‍💻.".utf16.count)
          ])
      ])

    fixture.answer = [ModelAnswerPart(kind: .quote, text: "A hidden fact 👩🏽‍💻")]
    await #expect(throws: IntelligenceError.unverifiedQuotation) {
      try await Intelligence(backend: fixture).ask(input)
    }

    let longBody = String(repeating: "# Part\nA visible paragraph.\n\n", count: 100) + "needle"
    let reader = FixtureModel()
    reader.contextSize = 1_536
    reader.excerpts = { $0.source.contains("needle") ? ["needle"] : [] }
    reader.answer = [ModelAnswerPart(kind: .quote, text: "needle")]
    _ = try await Intelligence(backend: reader).ask(
      request(prefix + longBody, .ask, "Find needle"))
    #expect(
      reader.passes.filter { $0.purpose == .extract }
        .map(\.source).joined().utf8.elementsEqual(longBody.utf8))
    #expect(!reader.passes.contains { $0.source.contains("private:") })
  }

  @Test func withNoEvidenceInTheFileAskSaysWhy() async {
    let fixture = FixtureModel()
    fixture.contextSize = 512
    await #expect(throws: IntelligenceError.noEvidence) {
      try await Intelligence(backend: fixture).ask(
        request(
          String(repeating: manga + "\n\n", count: 20), .ask, "Summarize my reading list"))
    }
    #expect(!fixture.passes.contains { $0.purpose == .answer })
  }
}
