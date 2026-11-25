import Foundation

@testable import Intelligence

/// A scripted model. It never calls Apple Intelligence.
@Observable final class FixtureLanguageModel: IntelligenceModel {
    static let source =
        "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."

    var contextSize = 4_096
    var unavailableReason: String?
    /// Keeps every pass waiting once it arrives, until the test sets this back to false or cancels.
    var isHeld = false
    var failure: (any Error)?
    var nextFailure: (any Error)?
    var answer = Answer.Reply(
        prose: "You leave at 9am, an hour after the cafe opens.", quotes: ["Leave at 9am"])
    var partialAnswers: [String] = []
    static var fixes: [Proposal.Change] {
        [
            Proposal.Change(quote: "teh", replacement: "the", reason: "Fix the spelling of “the”."),
            Proposal.Change(
                quote: "before the cafe opens", replacement: "after the cafe opens",
                reason: "9am is after the cafe opens at 8am."),
        ]
    }
    var operations: (ModelPass) -> [EditOperation] = { pass in
        fixes.map { .replaceRegion((pass.source as NSString).range(of: $0.quote), $0) }
    }
    var excerpts: (ModelPass) -> [String] = { _ in [] }
    private(set) var passes: [ModelPass] = []

    func tokenCount(for pass: ModelPass) async throws -> Int {
        64 + pass.source.utf16.count + pass.instruction.utf16.count
    }

    func operations(for pass: ModelPass) async throws -> [EditOperation] {
        try await record(pass)
        return operations(pass)
    }

    func excerpts(for pass: ModelPass) async throws -> [String] {
        try await record(pass)
        return excerpts(pass)
    }

    func reply(
        to pass: ModelPass, onUpdate: @MainActor (String) -> Void
    ) async throws -> Answer.Reply {
        try await record(pass)
        for partial in partialAnswers.isEmpty ? [answer.prose] : partialAnswers {
            onUpdate(partial)
        }
        return answer
    }

    private func record(_ pass: ModelPass) async throws {
        passes.append(pass)
        if isHeld {
            for await isHeld in Observations({ self.isHeld }) where !isHeld { break }
            try Task.checkCancellation()
        }
        if let nextFailure {
            self.nextFailure = nil
            throw nextFailure
        }
        if let failure { throw failure }
    }
}
