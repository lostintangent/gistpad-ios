#if DEBUG
  import Foundation

  /// A scripted model for tests and capture fixtures. It never calls Apple Intelligence.
  @MainActor
  public final class NoteModelFixture: NoteModelBackend {
    public static let source =
      "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."

    public var contextSize = 4_096
    public var unavailableReason: String?
    public var delay: Duration?
    public var failure: (any Error)?
    public var answer = [
      ModelAnswerPart(kind: .prose, text: "You leave at 9am, an hour after the cafe opens."),
      ModelAnswerPart(kind: .quote, text: "Leave at 9am"),
    ]
    public var changes: (NoteModelPass) -> [NoteEditOperation] = { _ in
      [
        .replace(
          NoteReplacementCandidate(
            quote: "teh", replacement: "the", reason: "Fix the spelling of “the”.")),
        .replace(
          NoteReplacementCandidate(
            quote: "before the cafe opens", replacement: "after the cafe opens",
            reason: "9am is after the cafe opens at 8am.")),
      ]
    }
    public var excerpts: (NoteModelPass) -> [String] = { _ in [] }
    public private(set) var passes: [NoteModelPass] = []

    public init() {}

    public func modelInfo() async throws -> NoteModelInfo {
      if let unavailableReason { throw NoteIntelligenceError.unavailable(unavailableReason) }
      return NoteModelInfo(variant: "Fixture", contextSize: contextSize)
    }

    public func tokenCount(for pass: NoteModelPass) async throws -> Int {
      64 + pass.source.utf16.count + pass.instruction.utf16.count
    }

    public func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation] {
      try await record(pass)
      return changes(pass)
    }

    public func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      try await editOperations(for: pass).compactMap {
        if case .replace(let candidate) = $0 { candidate } else { nil }
      }
    }

    public func excerpts(for pass: NoteModelPass) async throws -> [String] {
      try await record(pass)
      return excerpts(pass)
    }

    public func answer(for pass: NoteModelPass) async throws -> [ModelAnswerPart] {
      try await record(pass)
      return answer
    }

    private func record(_ pass: NoteModelPass) async throws {
      passes.append(pass)
      if let delay { try await Task.sleep(for: delay) }
      if let failure { throw failure }
    }
  }
#endif
