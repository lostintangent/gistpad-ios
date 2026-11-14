import Foundation
import FoundationModels

extension OnDeviceModel {
  package func replacements(for pass: ModelPass) async throws -> [ModelReplacement] {
    try await perform(pass: pass) {
      let session = Self.session(model: model, pass: pass)
      let response = try await session.respond(
        to: Self.prompt(for: pass), generating: AppleChanges.self,
        options: GenerationOptions(temperature: 0.2, maximumResponseTokens: pass.responseTokens))
      return response.content.changes.map {
        ModelReplacement(
          quote: $0.quote, replacement: $0.replacement, reason: $0.reason,
          before: $0.before, after: $0.after)
      }
    }
  }

  static let reviewInstructions = commonInstructions + """

      Review for concrete problems, not speculative stylistic preferences.
      Anchor every comment to the shortest exact source quote. Use exact before/after context
      when needed to distinguish repeats. Do not overlap quotes. Give a concise, actionable reason.
      Offer an exact replacement only when the correction is clear, otherwise use null.
      Return no changes when there are no actionable issues.
      """
}

@Generable
struct AppleChange: Sendable {
  @Guide(description: "Exact source text, including whitespace.")
  var quote: String
  @Guide(description: "Exact source text immediately before quote, or an empty string.")
  var before: String
  @Guide(description: "Exact source text immediately after quote, or an empty string.")
  var after: String
  @Guide(description: "New text only for the quoted passage. Never copy the user request here.")
  var replacement: String?
  @Guide(description: "A brief explanation of this specific change.")
  var reason: String
}

@Generable
struct AppleChanges: Sendable {
  @Guide(.maximumCount(12))
  var changes: [AppleChange]
}
