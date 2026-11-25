import Foundation
import Testing

@testable import Intelligence

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

    @Test func askAnswersAShortFileInOnePass() async throws {
        let fixture = FixtureLanguageModel()
        fixture.answer = Answer.Reply(
            prose: "You are reading two series and have two next reads.",
            quotes: ["1. Frieren, volume 8"])
        let short = request(manga, "Summarize my reading list")
        let answer = try await fixture.ask(short)
        #expect(answer.prose == fixture.answer.prose)
        #expect(answer.citations.map(\.text) == ["1. Frieren, volume 8"])
        #expect(fixture.passes.map(\.source) == [manga])
        #expect(fixture.passes.map(\.requestID) == [short.id])
    }

    @Test(arguments: [
        ("# Thanksgiving menu\n\nTwelve at the table this year,\nand dinner's at **4**.",
         "Thanksgiving menu\nTwelve at the table this year, and dinner's at 4."),
        ("| Dish | Who |\n| --- | :---: |\n| Turkey and gravy | Me |", "Dish\tWho\nTurkey and gravy\tMe"),
        ("> The turkey goes in at 10:30,\n> so the oven's free", "The turkey goes in at 10:30, so the oven's free"),
        ("- [ ] Brine the turkey\n2. Borrow Mom's [gravy boat](https://example.com)",
         "Brine the turkey\nBorrow Mom's gravy boat"),
        ("```swift\nlet *x* = 1\n```", "let *x* = 1"),
    ])
    func aCitationReadsLikePreview(quote: String, passage: String) {
        let citation = Answer.Citation(text: quote, ranges: [])
        #expect(String(citation.passage.characters) == passage)
    }

    @Test func aCitationCarriesTheExactPassageForShowInFile() async throws {
        let fixture = FixtureLanguageModel()
        fixture.answer = Answer.Reply(prose: "", quotes: ["👩🏽‍💻"])
        let answer = try await fixture.ask(
            request("Hello 👩🏽‍💻\r\n", "Quote the emoji"))
        #expect(
            answer.citations
                == [Answer.Citation(text: "👩🏽‍💻", ranges: [NSRange(location: 6, length: "👩🏽‍💻".utf16.count)])])
        #expect(answer.prose.isEmpty)

        let original = "# One\r\n\r\nFirst 👩🏽‍💻\r\n\r\n# Two\n\nSecond cafe\u{301}\n"
        let blocks = OnDeviceModel.SourceBlock.blocks(in: original)
        #expect(blocks.map(\.text).joined().utf8.elementsEqual(original.utf8))
        let reply = try OnDeviceModel.parseAnswer(
            "The second section answers.\n[Sources: 2]", blocks: blocks)
        #expect(reply.quotes == [blocks[1].text])
        let plain = try OnDeviceModel.parseAnswer(
            "The second section answers.\nSources: 2", blocks: blocks)
        #expect(plain == reply)
        #expect(
            try OnDeviceModel.parseAnswer(
                "The second section answers. [Sources: 2]", blocks: blocks) == reply)
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
        let fixture = FixtureLanguageModel()
        fixture.partialAnswers = ["Your", "Your note says"]
        fixture.answer = Answer.Reply(
            prose: "Your note says the route is south.", quotes: ["The route is south."])
        var updates: [String] = []
        let response = try await fixture.ask(
            request("The route is south.", "Which route?"),
            onPartialAnswer: { updates.append($0) })
        #expect(updates == ["", "Your", "Your note says"])
        #expect(
            response
                == Answer(
                    prose: "Your note says the route is south.",
                    citations: [
                        Answer.Citation(
                            text: "The route is south.",
                            ranges: [NSRange(location: 0, length: "The route is south.".utf16.count)])
                    ]))
    }

    @Test func anUnverifiedSourceIDGetsOneCleanRetry() async throws {
        let fixture = FixtureLanguageModel()
        fixture.nextFailure = IntelligenceError.unverifiedQuotation
        fixture.answer = Answer.Reply(prose: "The route is south.")
        var updates: [String] = []
        let answer = try await fixture.ask(
            request("The route is south.", "Which route?"),
            onPartialAnswer: { updates.append($0) })
        #expect(fixture.passes.map(\.purpose) == [.answer, .answer])
        #expect(updates == ["", "", "The route is south."])
        #expect(answer == Answer(prose: "The route is south."))
    }

    @Test func askReadsTheWholeBodyButNeverFrontMatter() async throws {
        let prefix = "---\r\nprivate: A hidden fact 👩🏽‍💻\r\n---\r\n\r\n"
        let body = "# Content\r\n\r\nA visible fact 👩🏽‍💻.\r\n"
        let fixture = FixtureLanguageModel()
        fixture.answer = Answer.Reply(prose: "", quotes: ["A visible fact 👩🏽‍💻."])
        let input = request(prefix + body, "What is visible?")
        let answer = try await fixture.ask(input)
        #expect(fixture.passes.map(\.source) == [body])
        #expect(
            answer
                == Answer(
                    prose: "",
                    citations: [
                        Answer.Citation(
                            text: "A visible fact 👩🏽‍💻.",
                            ranges: [
                                NSRange(
                                    location: prefix.utf16.count + "# Content\r\n\r\n".utf16.count,
                                    length: "A visible fact 👩🏽‍💻.".utf16.count)
                            ])
                    ]))

        fixture.answer = Answer.Reply(prose: "", quotes: ["A hidden fact 👩🏽‍💻"])
        await #expect(throws: IntelligenceError.unverifiedQuotation) {
            try await fixture.ask(input)
        }

        let longBody = String(repeating: "# Part\nA visible paragraph.\n\n", count: 100) + "needle"
        let reader = FixtureLanguageModel()
        reader.contextSize = 1_536
        reader.excerpts = { $0.source.contains("needle") ? ["needle"] : [] }
        reader.answer = Answer.Reply(prose: "", quotes: ["needle"])
        let found = try await reader.ask(
            request(prefix + longBody, "Find needle"))
        #expect(
            reader.passes.filter { $0.purpose == .extract }
                .map(\.source).joined().utf8.elementsEqual(longBody.utf8))
        #expect(reader.passes.filter { $0.purpose == .answer }.map(\.evidenceBlocks) == [["needle"]])
        #expect(found.citations.map(\.text) == ["needle"])
        #expect(!reader.passes.contains { $0.source.contains("private:") })
    }

    @Test func withNoEvidenceInTheFileAskSaysWhy() async {
        let fixture = FixtureLanguageModel()
        fixture.contextSize = 512
        await #expect(throws: IntelligenceError.noEvidence) {
            try await fixture.ask(
                request(
                    String(repeating: manga + "\n\n", count: 20), "Summarize my reading list"))
        }
        #expect(!fixture.passes.contains { $0.purpose == .answer })
    }
}
