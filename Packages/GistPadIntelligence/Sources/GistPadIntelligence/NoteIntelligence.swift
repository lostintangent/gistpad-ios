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
          "This request needs more context than the on-device model can safely combine. Your note is unchanged.",
        bundle: .module)
    case .invalidResponse, .responseTooLarge:
      String(
        localized: "Apple Intelligence returned an incomplete response. Your note is unchanged.",
        bundle: .module)
    case .emptyAnswer:
      String(
        localized: "Apple Intelligence didn't return an answer. Try again.", bundle: .module)
    case .unsafeEdit:
      String(
        localized:
          "This suggestion repeats your instruction or would leave almost none of your note. Nothing was changed. Try a more specific edit.",
        bundle: .module)
    case .unverifiedQuotation:
      String(
        localized:
          "A quoted passage didn't match your note. Try again.",
        bundle: .module)
    case .noEvidence:
      String(localized: "I couldn't find information about that in this note.", bundle: .module)
    case .staleSnapshot:
      String(
        localized: "Your note changed. Generate a fresh result before applying changes.",
        bundle: .module)
    case .noApplicableChanges:
      String(localized: "There are no verified changes to apply.", bundle: .module)
    case .invalidSelection:
      String(
        localized: "The editor selection is no longer valid. Your note is unchanged.",
        bundle: .module)
    case .refused:
      String(
        localized: "Apple Intelligence couldn't complete this request. Your note is unchanged.",
        bundle: .module)
    case .rateLimited:
      String(localized: "Apple Intelligence is busy. Try again in a moment.", bundle: .module)
    case .timedOut:
      String(
        localized: "Apple Intelligence took too long to respond. Try again.", bundle: .module)
    }
  }

  public var diagnosticCode: String {
    switch self {
    case .unavailable: "unavailable"
    case .emptyInstruction: "emptyInstruction"
    case .insufficientContext: "insufficientContext"
    case .invalidResponse: "invalidResponse"
    case .emptyAnswer: "emptyAnswer"
    case .unsafeEdit: "unsafeEdit"
    case .responseTooLarge: "responseTooLarge"
    case .unverifiedQuotation: "unverifiedQuotation"
    case .noEvidence: "noEvidence"
    case .staleSnapshot: "staleSnapshot"
    case .noApplicableChanges: "noApplicableChanges"
    case .invalidSelection: "invalidSelection"
    case .refused: "refused"
    case .rateLimited: "rateLimited"
    case .timedOut: "timedOut"
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
  public let evidenceOnly: Bool
  public let requestID: UUID
  public let tasks: [NoteTask]

  public init(
    purpose: Purpose, instruction: String, source: String, responseTokens: Int,
    evidenceOnly: Bool = false, requestID: UUID = UUID(), tasks: [NoteTask] = []
  ) {
    self.purpose = purpose
    self.instruction = instruction
    self.source = source
    self.responseTokens = responseTokens
    self.evidenceOnly = evidenceOnly
    self.requestID = requestID
    self.tasks = tasks
  }
}

public struct NoteTask: Sendable {
  public let id: Int
  public let range: NSRange
  public let text: String
  public let isComplete: Bool

  public init(id: Int, range: NSRange, text: String, isComplete: Bool) {
    self.id = id
    self.range = range
    self.text = text
    self.isComplete = isComplete
  }
}

public enum NoteEditOperation: Sendable {
  case replace(NoteReplacementCandidate)
  case setTaskStates(ids: [Int]?, isComplete: Bool)
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
  public let snapshot: NoteSnapshot
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
  func beginAttempt(id: UUID, action: NoteIntelligenceAction)
  func finishAttempt(id: UUID, errorCode: String?, errorType: String?)
  func modelInfo() async throws -> NoteModelInfo
  func tokenCount(for pass: NoteModelPass) async throws -> Int
  func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate]
  func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation]
  func excerpts(for pass: NoteModelPass) async throws -> [String]
  func answer(
    for pass: NoteModelPass,
    onUpdate: @MainActor ([ModelAnswerPart]) -> Void
  ) async throws -> [ModelAnswerPart]
}

extension NoteModelBackend {
  public func beginAttempt(id: UUID, action: NoteIntelligenceAction) {}
  public func finishAttempt(id: UUID, errorCode: String?, errorType: String?) {}
  public func editOperations(for pass: NoteModelPass) async throws -> [NoteEditOperation] {
    try await replacements(for: pass).map(NoteEditOperation.replace)
  }
}
