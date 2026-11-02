import Foundation

public struct NoteSnapshot: Sendable, Equatable {
  public let documentID: String
  public let sessionID: UUID
  public let generation: UInt64
  public let source: String
  public let headingOffsets: [Int]
  public let tasks: [NoteTask]

  public init(
    documentID: String, sessionID: UUID, generation: UInt64, source: String,
    headingOffsets: [Int] = [], tasks: [NoteTask] = []
  ) {
    self.documentID = documentID
    self.sessionID = sessionID
    self.generation = generation
    self.source = source
    self.headingOffsets = headingOffsets
    self.tasks = tasks
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.documentID == rhs.documentID && lhs.sessionID == rhs.sessionID
      && lhs.generation == rhs.generation && lhs.source.utf8.elementsEqual(rhs.source.utf8)
  }
}

public enum NoteIntelligenceAction: String, CaseIterable, Sendable {
  case ask, edit, review
}

public struct NoteIntelligenceRequest: Sendable {
  public let id: UUID
  public let snapshot: NoteSnapshot
  public let action: NoteIntelligenceAction
  public let instruction: String

  public init(
    snapshot: NoteSnapshot, action: NoteIntelligenceAction, instruction: String = "",
    id: UUID = UUID()
  ) {
    self.id = id
    self.snapshot = snapshot
    self.action = action
    self.instruction = instruction
  }
}

public enum NoteIntelligenceError: Error, LocalizedError, Sendable, Equatable {
  case unavailable(String)
  case emptyInstruction
  case insufficientContext
  case invalidResponse
  case emptyAnswer
  case invalidAnswer(NoteAnswerIssue)
  case invalidEdit
  case unsafeEdit
  case responseTooLarge
  case unverifiedQuotation
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

public struct NoteModelInfo: Sendable {
  public let variant: String
  public let contextSize: Int

  public init(variant: String, contextSize: Int) {
    self.variant = variant
    self.contextSize = contextSize
  }
}

public struct NoteModelPass: Sendable {
  public enum Purpose: String, Sendable { case answer, extract, edit, review }
  public let purpose: Purpose
  public let instruction: String
  public let source: String
  public let responseTokens: Int
  public let requestID: UUID
  public let tasks: [NoteTask]
  public let evidenceBlocks: [String]?

  public init(
    purpose: Purpose, instruction: String, source: String, responseTokens: Int,
    requestID: UUID = UUID(), tasks: [NoteTask] = [],
    evidenceBlocks: [String]? = nil
  ) {
    self.purpose = purpose
    self.instruction = instruction
    self.source = source
    self.responseTokens = responseTokens
    self.requestID = requestID
    self.tasks = tasks
    self.evidenceBlocks = evidenceBlocks
  }
}

public struct NoteTask: Sendable {
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
  ) -> [NoteTask] {
    let text = source as NSString
    var previousEnd: Int?
    var listID = 0
    return markers.sorted { $0.location < $1.location }.enumerated().map { index, marker in
      let line = text.lineRange(for: marker)
      if previousEnd != line.location { listID += 1 }
      previousEnd = NSMaxRange(line)
      let heading = headings.last { NSMaxRange($0) <= line.location }
      return NoteTask(
        id: index + 1, range: marker,
        text: text.substring(with: line).trimmingCharacters(in: .newlines),
        isComplete: text.substring(with: marker) != "[ ]",
        listID: listID, listTitle: heading.map { text.substring(with: $0) } ?? "")
    }
  }
}

public enum NoteEditOperation: Sendable {
  case replace(NoteReplacementCandidate)
  case setTaskStates(ids: [Int]?, isComplete: Bool)
  case insertTask(listID: Int, text: String)
  case deleteTasks(ids: [Int])
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

public struct NoteCitation: Sendable, Equatable {
  public let quote: String
  public let ranges: [NSRange]
}

public enum NoteAnswerPart: Sendable, Equatable {
  case prose(String)
  case quotation(NoteCitation)
}

public struct NoteAnswer: Sendable {
  public let parts: [NoteAnswerPart]
}

public struct NoteIntelligenceProgress: Sendable {
  public enum Phase: Sendable { case reading, editing, reviewing, combining, answering }
  public let phase: Phase
  public let current: Int
  public let total: Int
}

@MainActor
public protocol NoteModelBackend {
  func modelInfo() async throws -> NoteModelInfo
  func tokenCount(for pass: NoteModelPass) async throws -> Int
  func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate]
  func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation]
  func excerpts(for pass: NoteModelPass) async throws -> [String]
  func answer(for pass: NoteModelPass) async throws -> [ModelAnswerPart]
}

extension NoteModelBackend {
  public func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation] {
    try await replacements(for: pass).map(NoteEditOperation.replace)
  }
}
