import Foundation
import FoundationModels
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
    #expect(answer.parts.count == 2)
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
    #expect(found.parts.count == 1)
  }

  @Test func aCitationCarriesTheExactPassageForShowInFile() async throws {
    let fixture = FixtureModel()
    fixture.answer = [ModelAnswerPart(kind: .quote, text: "👩🏽‍💻")]
    let answer = try await Intelligence(backend: fixture).ask(
      request("Hello 👩🏽‍💻\r\n", .ask, "Quote the emoji"))
    #expect(
      answer.parts == [
        .quotation(
          Citation(
            quote: "👩🏽‍💻", ranges: [NSRange(location: 6, length: "👩🏽‍💻".utf16.count)]))
      ])

    let original = "# One\r\n\r\nFirst 👩🏽‍💻\r\n\r\n# Two\n\nSecond cafe\u{301}\n"
    let blocks = SourceBlock.blocks(in: original)
    #expect(blocks.map(\.text).joined().utf8.elementsEqual(original.utf8))
    let parts = try OnDeviceModel.decodeAnswer(
      GeneratedContent(json: #"{"blockIDs":[2],"answer":"The second section answers."}"#),
      blocks: blocks)
    #expect(parts.last == ModelAnswerPart(kind: .quote, text: blocks[1].text))
    #expect(throws: IntelligenceError.unverifiedQuotation) {
      try OnDeviceModel.decodeAnswer(
        GeneratedContent(json: #"{"blockIDs":[99],"answer":"An answer"}"#), blocks: blocks)
    }
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
