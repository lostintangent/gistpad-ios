import Foundation
import FoundationModels

extension OnDeviceModel {
    package func suggestions(for pass: ModelPass) async throws -> [Proposal.Change] {
        try await perform(pass: pass) {
            let session = session(for: pass)
            let response = try await session.respond(
                to: Self.prompt(for: pass), generating: Suggestions.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: pass.responseTokens))
            return response.content.suggestions.map {
                Proposal.Change(
                    quote: $0.quote, replacement: $0.replacement, reason: $0.reason,
                    before: $0.before, after: $0.after)
            }
        }
    }

    static let reviewInstructions = commonInstructions + """

            Review for concrete problems, not speculative stylistic preferences.
            Anchor every suggestion to the shortest exact source quote. Use exact before/after context
            when needed to distinguish repeats. Do not overlap quotes. Give a concise, actionable reason.
            Offer an exact replacement only when the correction is clear, otherwise use null.
            Return no suggestions when there are no actionable issues.
            """
}

extension OnDeviceModel {
    @Generable
    struct Suggestion {
        @Guide(description: "Exact source text, including whitespace.")
        var quote: String
        @Guide(description: "Exact source text immediately before quote, or an empty string.")
        var before: String
        @Guide(description: "Exact source text immediately after quote, or an empty string.")
        var after: String
        @Guide(description: "New text only for the quoted passage. Never copy the user request here.")
        var replacement: String?
        @Guide(description: "A brief explanation of this specific suggestion.")
        var reason: String
    }

    @Generable
    struct Suggestions {
        @Guide(.maximumCount(12))
        var suggestions: [Suggestion]
    }
}
