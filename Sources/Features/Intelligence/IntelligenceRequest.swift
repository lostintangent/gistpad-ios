import Foundation

package struct FileSnapshot: Sendable, Equatable {
  let fileID: String
  let sessionID: UUID
  let generation: UInt64
  package let source: String
  var headingOffsets: [Int] = []
  package var tasks: [ModelTask] = []

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.fileID == rhs.fileID && lhs.sessionID == rhs.sessionID
      && lhs.generation == rhs.generation && lhs.source.utf8.elementsEqual(rhs.source.utf8)
  }
}

package enum IntelligenceAction: String, CaseIterable, Sendable {
  case ask, edit, review
}

package struct IntelligenceRequest: Sendable {
  package let id: UUID
  package let snapshot: FileSnapshot
  package let action: IntelligenceAction
  let instruction: String

  package init(
    snapshot: FileSnapshot, action: IntelligenceAction, instruction: String = "",
    id: UUID = UUID()
  ) {
    self.id = id
    self.snapshot = snapshot
    self.action = action
    self.instruction = instruction
  }
}

package enum IntelligenceError: Error, LocalizedError, Sendable, Equatable {
  case unavailable(String)
  case emptyInstruction
  case insufficientContext
  case invalidResponse
  case emptyAnswer
  case invalidAnswer(AnswerIssue)
  case invalidEdit
  case unsafeEdit
  case responseTooLarge
  case unverifiedQuotation
  case noteTooLong
  case noEvidence
  case staleSnapshot
  case noApplicableChanges
  case invalidSelection
  case refused
  case rateLimited
  case timedOut

  package var errorDescription: String? {
    switch self {
    case .unavailable(let reason): reason
    case .emptyInstruction:
      String(localized: "Enter what you would like to ask or change.", bundle: .module)
    case .insufficientContext:
      String(
        localized:
          "This request needs more context than the on-device model can safely combine. Your file is unchanged.",
        bundle: .module)
    case .invalidResponse:
      String(
        localized:
          "Apple Intelligence returned a response the app couldn't read. Your file is unchanged.",
        bundle: .module)
    case .responseTooLarge:
      String(
        localized:
          "Apple Intelligence reached the response limit before finishing. Your file is unchanged.",
        bundle: .module)
    case .invalidEdit:
      String(
        localized:
          "Apple Intelligence returned an edit that couldn't be found in your file. Nothing was changed.",
        bundle: .module)
    case .emptyAnswer:
      String(
        localized: "Apple Intelligence didn't return an answer. Try again.", bundle: .module)
    case .invalidAnswer:
      String(
        localized:
          "Apple Intelligence couldn't produce a clear, grounded answer. Try again.",
        bundle: .module)
    case .unsafeEdit:
      String(
        localized:
          "This edit repeats your instruction or would leave almost none of your file. Nothing was changed.",
        bundle: .module)
    case .noteTooLong:
      String(
        localized: "This file is too long to edit at once. Select a section and use Writing Tools.",
        bundle: .module)
    case .unverifiedQuotation:
      String(
        localized: "A quoted passage didn't match your file.", bundle: .module)
    case .noEvidence:
      String(localized: "I couldn't find that in this file.", bundle: .module)
    case .staleSnapshot:
      String(
        localized: "This file has changed since this result.",
        bundle: .module)
    case .noApplicableChanges:
      String(localized: "There are no verified changes to apply.", bundle: .module)
    case .invalidSelection:
      String(
        localized: "The editor selection is no longer valid. Your file is unchanged.",
        bundle: .module)
    case .refused:
      String(
        localized: "Apple Intelligence couldn't complete this request. Your file is unchanged.",
        bundle: .module)
    case .rateLimited:
      String(localized: "Apple Intelligence is busy. Try again in a moment.", bundle: .module)
    case .timedOut:
      String(
        localized: "Apple Intelligence took too long to respond. Try again.", bundle: .module)
    }
  }
}

package struct ModelInfo: Sendable {
  package let variant: String
  package let contextSize: Int
}

package struct ModelPass: Sendable {
  enum Purpose: String, Sendable { case answer, extract, edit, review }
  let purpose: Purpose
  package let instruction: String
  package let source: String
  let responseTokens: Int
  var requestID = UUID()
  var tasks: [ModelTask] = []
  var evidenceBlocks: [String]?
  /// Whether the source is one part of a note too long for one pass.
  var isPart = false
}

package struct ModelTask: Sendable {
  let id: Int
  package let range: NSRange
  package let text: String
  package let isComplete: Bool
  var listID = 1
  package var listTitle = ""

  static func indexed(
    in source: String, markers: [NSRange], headings: [NSRange]
  ) -> [ModelTask] {
    let text = source as NSString
    var previousEnd: Int?
    var listID = 0
    return markers.sorted { $0.location < $1.location }.enumerated().map { index, marker in
      let line = text.lineRange(for: marker)
      if previousEnd != line.location { listID += 1 }
      previousEnd = NSMaxRange(line)
      let heading = headings.last { NSMaxRange($0) <= line.location }
      return ModelTask(
        id: index + 1, range: marker,
        text: text.substring(with: line).trimmingCharacters(in: .newlines),
        isComplete: text.substring(with: marker) != "[ ]",
        listID: listID, listTitle: heading.map { text.substring(with: $0) } ?? "")
    }
  }
}

package enum ModelEdit: Sendable {
  case replace(ModelReplacement)
  case setTaskStates(ids: [Int]?, isComplete: Bool)
  case insertTask(listID: Int, text: String)
  case deleteTasks(ids: [Int])
  /// The whole note as the model revised it, which the app compares line by line.
  case rewrite(String)
  /// A selected body block, using a UTF-16 range relative to the model pass.
  case rewriteRegion(NSRange, revised: String)
  case replaceRegion(NSRange, ModelReplacement)
}

package struct ModelAnswerPart: Sendable, Equatable {
  package enum Kind: Sendable { case prose, quote }
  package let kind: Kind
  package let text: String
}

/// An answer's prose, or a quotation verified at its ranges in the note.
package enum AnswerPart: Sendable, Equatable {
  case prose(String)
  case quotation(String, ranges: [NSRange])
}

package struct IntelligenceProgress: Sendable {
  package enum Phase: Sendable { case reading, editing, reviewing, combining, answering }
  package let phase: Phase
  let current: Int
  let total: Int
}

@MainActor
package protocol IntelligenceModel {
  func modelInfo() async throws -> ModelInfo
  func tokenCount(for pass: ModelPass) async throws -> Int
  func replacements(for pass: ModelPass) async throws -> [ModelReplacement]
  func editOperations(for pass: ModelPass) async throws -> [ModelEdit]
  func excerpts(for pass: ModelPass) async throws -> [String]
  func answer(for pass: ModelPass) async throws -> [ModelAnswerPart]
  func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> [ModelAnswerPart]
}

extension IntelligenceModel {
  package func editOperations(for pass: ModelPass) async throws -> [ModelEdit] {
    try await replacements(for: pass).map(ModelEdit.replace)
  }

  package func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> [ModelAnswerPart] {
    let parts = try await answer(for: pass)
    onUpdate(parts.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n"))
    return parts
  }
}
