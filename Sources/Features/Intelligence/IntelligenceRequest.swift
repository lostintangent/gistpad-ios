import Foundation

public struct FileSnapshot: Sendable, Equatable {
  public let fileID: String
  public let sessionID: UUID
  public let generation: UInt64
  public let source: String
  public let headingOffsets: [Int]
  public let tasks: [ModelTask]

  public init(
    fileID: String, sessionID: UUID, generation: UInt64, source: String,
    headingOffsets: [Int] = [], tasks: [ModelTask] = []
  ) {
    self.fileID = fileID
    self.sessionID = sessionID
    self.generation = generation
    self.source = source
    self.headingOffsets = headingOffsets
    self.tasks = tasks
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.fileID == rhs.fileID && lhs.sessionID == rhs.sessionID
      && lhs.generation == rhs.generation && lhs.source.utf8.elementsEqual(rhs.source.utf8)
  }
}

public enum IntelligenceAction: String, CaseIterable, Sendable {
  case ask, edit, review
}

public struct IntelligenceRequest: Sendable {
  public let id: UUID
  public let snapshot: FileSnapshot
  public let action: IntelligenceAction
  public let instruction: String

  public init(
    snapshot: FileSnapshot, action: IntelligenceAction, instruction: String = "",
    id: UUID = UUID()
  ) {
    self.id = id
    self.snapshot = snapshot
    self.action = action
    self.instruction = instruction
  }
}

public enum IntelligenceError: Error, LocalizedError, Sendable, Equatable {
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

  public var errorDescription: String? {
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

public struct ModelInfo: Sendable {
  public let variant: String
  public let contextSize: Int

  public init(variant: String, contextSize: Int) {
    self.variant = variant
    self.contextSize = contextSize
  }
}

public struct ModelPass: Sendable {
  public enum Purpose: String, Sendable { case answer, extract, edit, review }
  public let purpose: Purpose
  public let instruction: String
  public let source: String
  public let responseTokens: Int
  public let requestID: UUID
  public let tasks: [ModelTask]
  public let evidenceBlocks: [String]?
  /// Whether the source is one part of a note too long for one pass.
  public let isPart: Bool

  public init(
    purpose: Purpose, instruction: String, source: String, responseTokens: Int,
    requestID: UUID = UUID(), tasks: [ModelTask] = [],
    evidenceBlocks: [String]? = nil, isPart: Bool = false
  ) {
    self.purpose = purpose
    self.instruction = instruction
    self.source = source
    self.responseTokens = responseTokens
    self.requestID = requestID
    self.tasks = tasks
    self.evidenceBlocks = evidenceBlocks
    self.isPart = isPart
  }
}

public struct ModelTask: Sendable {
  public let id: Int
  public let range: NSRange
  public let text: String
  public let isComplete: Bool
  public let listID: Int
  public let listTitle: String

  public init(
    id: Int, range: NSRange, text: String, isComplete: Bool,
    listID: Int = 1, listTitle: String = ""
  ) {
    self.id = id
    self.range = range
    self.text = text
    self.isComplete = isComplete
    self.listID = listID
    self.listTitle = listTitle
  }

  public static func indexed(
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

public enum ModelEdit: Sendable {
  case replace(ModelReplacement)
  case setTaskStates(ids: [Int]?, isComplete: Bool)
  case insertTask(listID: Int, text: String)
  case deleteTasks(ids: [Int])
  /// The whole note as the model revised it, which the app compares line by line.
  case rewrite(String)
}

public struct ModelAnswerPart: Sendable, Equatable {
  public enum Kind: Sendable { case prose, quote }
  public let kind: Kind
  public let text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

public struct Citation: Sendable, Equatable {
  public let quote: String
  public let ranges: [NSRange]
}

public struct Answer: Sendable {
  public let parts: [Part]
}

extension Answer {
  public enum Part: Sendable, Equatable {
    case prose(String)
    case quotation(Citation)
  }
}

public struct IntelligenceProgress: Sendable {
  public enum Phase: Sendable { case reading, editing, reviewing, combining, answering }
  public let phase: Phase
  public let current: Int
  public let total: Int
}

@MainActor
public protocol IntelligenceModel {
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
  public func editOperations(for pass: ModelPass) async throws -> [ModelEdit] {
    try await replacements(for: pass).map(ModelEdit.replace)
  }

  public func streamAnswer(
    for pass: ModelPass, onUpdate: @MainActor (String) -> Void
  ) async throws -> [ModelAnswerPart] {
    let parts = try await answer(for: pass)
    onUpdate(parts.filter { $0.kind == .prose }.map(\.text).joined(separator: "\n\n"))
    return parts
  }
}
