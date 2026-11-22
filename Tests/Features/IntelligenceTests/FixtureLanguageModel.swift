import Foundation

@testable import Intelligence

/// A scripted model. It never calls Apple Intelligence.
final class FixtureLanguageModel: IntelligenceModel {
  static let source =
    "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."

  var contextSize = 4_096
  var unavailableReason: String?
  var delay: Duration?
  var failure: (any Error)?
  var nextFailure: (any Error)?
  var answer = ModelAnswer(
    prose: "You leave at 9am, an hour after the cafe opens.", quotes: ["Leave at 9am"])
  var partialAnswers: [String] = []
  var changes: (ModelPass) -> [ModelEdit] = { _ in
    [
      .replace(
        Proposal.Change(
          quote: "teh", replacement: "the", reason: "Fix the spelling of “the”.")),
      .replace(
        Proposal.Change(
          quote: "before the cafe opens", replacement: "after the cafe opens",
          reason: "9am is after the cafe opens at 8am.")),
    ]
  }
  var excerpts: (ModelPass) -> [String] = { _ in [] }
  private(set) var passes: [ModelPass] = []

  func modelInfo() async throws -> ModelInfo {
    if let unavailableReason { throw IntelligenceError.unavailable(unavailableReason) }
    return ModelInfo(variant: "Fixture", contextSize: contextSize)
  }

  func tokenCount(for pass: ModelPass) async throws -> Int {
    64 + pass.source.utf16.count + pass.instruction.utf16.count
  }

  func editOperations(for pass: ModelPass) async throws -> [ModelEdit] {
    try await record(pass)
    return changes(pass)
  }

  func excerpts(for pass: ModelPass) async throws -> [String] {
    try await record(pass)
    return excerpts(pass)
  }

  func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> ModelAnswer {
    try await record(pass)
    for partial in partialAnswers.isEmpty ? [answer.prose] : partialAnswers {
      onUpdate(partial)
    }
    return answer
  }

  private func record(_ pass: ModelPass) async throws {
    passes.append(pass)
    if let delay { try await Task.sleep(for: delay) }
    if let nextFailure {
      self.nextFailure = nil
      throw nextFailure
    }
    if let failure { throw failure }
  }
}
