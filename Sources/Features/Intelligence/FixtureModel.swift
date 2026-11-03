#if DEBUG
  import Foundation

  /// A scripted model for tests and capture fixtures. It never calls Apple Intelligence.
  @MainActor
  final class FixtureModel: IntelligenceModel {
    static let source =
      "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."

    var contextSize = 4_096
    var unavailableReason: String?
    var delay: Duration?
    var failure: (any Error)?
    var nextFailure: (any Error)?
    var answer = [
      ModelAnswerPart(kind: .prose, text: "You leave at 9am, an hour after the cafe opens."),
      ModelAnswerPart(kind: .quote, text: "Leave at 9am"),
    ]
    var partialAnswers: [String] = []
    var changes: (ModelPass) -> [ModelEdit] = { _ in
      [
        .replace(
          ModelReplacement(
            quote: "teh", replacement: "the", reason: "Fix the spelling of “the”.")),
        .replace(
          ModelReplacement(
            quote: "before the cafe opens", replacement: "after the cafe opens",
            reason: "9am is after the cafe opens at 8am.")),
      ]
    }
    var excerpts: (ModelPass) -> [String] = { _ in [] }
    private(set) var passes: [ModelPass] = []

    init() {}

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

    func replacements(for pass: ModelPass) async throws -> [ModelReplacement] {
      try await editOperations(for: pass).compactMap {
        if case .replace(let candidate) = $0 { candidate } else { nil }
      }
    }

    func excerpts(for pass: ModelPass) async throws -> [String] {
      try await record(pass)
      return excerpts(pass)
    }

    func answer(for pass: ModelPass) async throws -> [ModelAnswerPart] {
      try await record(pass)
      return answer
    }

    func streamAnswer(
      for pass: ModelPass, onUpdate: @MainActor (String) -> Void
    ) async throws -> [ModelAnswerPart] {
      try await record(pass)
      let prose = answer.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n")
      for partial in partialAnswers.isEmpty ? [prose] : partialAnswers {
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
#endif
