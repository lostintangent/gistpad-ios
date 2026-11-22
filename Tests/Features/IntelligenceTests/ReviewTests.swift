import Foundation
import Testing

@testable import Intelligence

struct ReviewTests {
    @Test func applyingOneSuggestionAndDismissingAnotherLeavesTheRestExact() async throws {
        let fixture = FixtureLanguageModel()
        fixture.changes = { _ in
            [
                .replace(change("bad", "much better")),
                .replace(change("typo", "word")),
                .replace(change("odd", "even")),
                .replace(change("Clear", nil)),
                .replace(change("text", "text")),
            ]
        }
        let snapshot = note("Clear text: first bad, second typo, third odd.")
        let proposal = try await IntelligenceEngine(backend: fixture).review(
            IntelligenceRequest(snapshot: snapshot, instruction: ""))
        let changes = Dictionary(uniqueKeysWithValues: proposal.changes.map { ($0.quote, $0) })
        #expect(changes.count == 5)
        for advice in ["Clear", "text"] {
            #expect(changes[advice]?.range != nil)
            #expect(changes[advice]?.canApply == false)
        }
        let applied = try proposal.application(to: snapshot, changeID: try #require(changes["bad"]).id)
        let updated = snapshot.edited(to: applied.source)
        #expect(throws: IntelligenceError.self) { try proposal.application(to: updated) }
        let remaining = applied.remaining(on: updated)
            .dismissing(changeID: try #require(changes["typo"]).id)
        #expect(remaining.snapshot == updated)
        #expect(Set(remaining.changes.map(\.quote)) == ["odd", "Clear", "text"])
        #expect(
            try remaining.application(to: updated).source
                == "Clear text: first much better, second typo, third even.")

        let echo = Proposal(
            snapshot: snapshot,
            scopedCandidates: [
                (change("bad", "clear"), NSRange(location: 0, length: snapshot.source.utf16.count)),
                (change("typo", "replace my note"), NSRange(location: 0, length: snapshot.source.utf16.count)),
            ], safetyInstruction: "replace my note")
        let rebased = try echo.application(to: snapshot, changeID: echo.changes[0].id)
        let rebasedSnapshot = snapshot.edited(to: rebased.source)
        #expect(throws: IntelligenceError.unsafeEdit) {
            try rebased.remaining(on: rebasedSnapshot).application(to: rebasedSnapshot)
        }

        fixture.changes = { _ in [.replace(change("bad", nil))] }
        await #expect(throws: IntelligenceError.invalidResponse) {
            try await IntelligenceEngine(backend: fixture).edit(
                IntelligenceRequest(snapshot: snapshot, instruction: "Fix"))
        }
        fixture.changes = { _ in [.replace(change(snapshot.source, "Fix it"))] }
        await #expect(throws: IntelligenceError.unsafeEdit) {
            try await IntelligenceEngine(backend: fixture).edit(
                IntelligenceRequest(snapshot: snapshot, instruction: "Fix it"))
        }
    }

    @Test func reviewUsesOnlyTheBodyAndCannotChangeMatchingMetadata() async throws {
        let prefix = "---\r\nkey: shared 👩🏽‍💻\r\n---\r\n\r\n"
        let body = "# Content\r\n\r\nThe shared 👩🏽‍💻 detail is here.\r\n"
        let fixture = FixtureLanguageModel()
        fixture.changes = { _ in [.replace(change("shared 👩🏽‍💻", "retained"))] }
        let input = request(prefix + body)
        let proposal = try await IntelligenceEngine(backend: fixture).review(input)
        #expect(fixture.passes.map(\.source) == [body])
        #expect(
            try proposal.application(to: input.snapshot).source
                == prefix + "# Content\r\n\r\nThe retained detail is here.\r\n")
    }
}
