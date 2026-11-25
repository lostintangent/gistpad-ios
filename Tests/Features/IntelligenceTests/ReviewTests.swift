import Foundation
import Testing

@testable import Intelligence

struct ReviewTests {
    @Test func applyingOneSuggestionAndDismissingAnotherLeavesTheRestExact() async throws {
        let fixture = FixtureLanguageModel()
        fixture.suggestions = { _ in
            [
                change("bad", "much better"),
                change("typo", "word"),
                change("odd", "even"),
                change("Clear", nil),
                change("text", "text"),
            ]
        }
        let document = note("Clear text: first bad, second typo, third odd.")
        let proposal = try await fixture.review(IntelligenceRequest(document: document))
        let changes = Dictionary(uniqueKeysWithValues: proposal.changes.map { ($0.quote, $0) })
        #expect(changes.count == 5)
        for advice in ["Clear", "text"] {
            #expect(changes[advice]?.range != nil)
            #expect(changes[advice]?.canApply == false)
        }
        let applied = try proposal.application(changeID: try #require(changes["bad"]).id)
        let remaining = applied.remaining(on: note(applied.source))
            .dismissing(changeID: try #require(changes["typo"]).id)
        #expect(Set(remaining.changes.map(\.quote)) == ["odd", "Clear", "text"])
        #expect(
            try remaining.application().source
                == "Clear text: first much better, second typo, third even.")

        let echo = Proposal(
            document: document,
            scopedCandidates: [
                (change("bad", "clear"), document.range),
                (change("typo", "replace my note"), document.range),
            ], safetyInstruction: "replace my note")
        let rebased = try echo.application(changeID: echo.changes[0].id)
        #expect(throws: IntelligenceError.unsafeEdit) {
            try rebased.remaining(on: note(rebased.source)).application()
        }

        fixture.operations = { pass in
            [.replaceRegion((pass.source as NSString).range(of: "bad"), change("bad", nil))]
        }
        await #expect(throws: IntelligenceError.invalidResponse) {
            try await fixture.edit(
                IntelligenceRequest(document: document, instruction: "Fix"))
        }
        fixture.operations = { pass in
            [
                .replaceRegion(
                    NSRange(location: 0, length: pass.source.utf16.count), change(pass.source, "Fix it"))
            ]
        }
        await #expect(throws: IntelligenceError.unsafeEdit) {
            try await fixture.edit(
                IntelligenceRequest(document: document, instruction: "Fix it"))
        }
    }

    @Test func reviewUsesOnlyTheBodyAndCannotChangeMatchingMetadata() async throws {
        let prefix = "---\r\nkey: shared 👩🏽‍💻\r\n---\r\n\r\n"
        let body = "# Content\r\n\r\nThe shared 👩🏽‍💻 detail is here.\r\n"
        let fixture = FixtureLanguageModel()
        fixture.suggestions = { _ in [change("shared 👩🏽‍💻", "retained")] }
        let input = request(prefix + body)
        let proposal = try await fixture.review(input)
        #expect(fixture.passes.map(\.source) == [body])
        #expect(
            try proposal.application().source
                == prefix + "# Content\r\n\r\nThe retained detail is here.\r\n")
    }
}
