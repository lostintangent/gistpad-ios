import Foundation
import Testing

@testable import IntelligenceEval

@MainActor
struct ReviewGradingTests {
    let clean = "# Packing\n\nBring a jacket, a water bottle and the train tickets.\n"

    @Test func aCleanNotePassesOnlyWithNoSuggestions() {
        #expect(Evaluator.reviewFailure(issues: [], in: clean, anchored: [], omitted: 0) == nil)
        #expect(
            Evaluator.reviewFailure(
                issues: [], in: clean, anchored: [NSRange(location: 11, length: 53)], omitted: 0)
                == "unwantedSuggestion")
    }

    @Test func aSeededIssueNeedsAnAnchoredSuggestionOverIt() {
        let source = "Take teh river path.\n"
        let typo = NSRange(location: 5, length: 3)
        #expect(Evaluator.reviewFailure(issues: ["teh"], in: source, anchored: [typo], omitted: 0) == nil)
        #expect(
            Evaluator.reviewFailure(issues: ["teh"], in: source, anchored: [], omitted: 1) == "issueMissed")
        #expect(
            Evaluator.reviewFailure(issues: ["teh"], in: source, anchored: [typo], omitted: 1)
                == "omittedChanges")
    }
}
