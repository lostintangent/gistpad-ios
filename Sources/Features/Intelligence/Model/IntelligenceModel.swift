import Foundation

package protocol IntelligenceModel {
    /// Why the model can't run right now, or nil when it can. Views that read it stay current.
    var unavailableReason: String? { get }
    /// The tokens one session holds, its instructions, prompt and response together.
    var contextSize: Int { get }
    func tokenCount(for pass: ModelPass) async throws -> Int
    func operations(for pass: ModelPass) async throws -> [EditOperation]
    func suggestions(for pass: ModelPass) async throws -> [Proposal.Change]
    func excerpts(for pass: ModelPass) async throws -> [String]
    /// Ask's reply, streaming its visible prose to `onUpdate`.
    func reply(
        to pass: ModelPass, onUpdate: @MainActor (String) -> Void
    ) async throws -> Answer.Reply
}

package struct ModelPass: Sendable {
    enum Purpose: String { case answer, extract, edit, review }
    // Platform gap: GenerationOptions has no repetition penalty or stop sequence, so a runaway answer
    // runs to this limit and is retried once. Remove the retry and raise the limit when it has one.
    /// Real answers use under 120 tokens.
    static let answerTokens = 384
    let purpose: Purpose
    package let instruction: String
    package let source: String
    let responseTokens: Int
    var requestID = UUID()
    var evidenceBlocks: [String]?
    /// Whether the source is one part of a note too long for one pass.
    var isPart = false
}

