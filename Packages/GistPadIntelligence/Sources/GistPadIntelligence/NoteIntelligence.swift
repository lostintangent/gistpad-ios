import Foundation

public struct NoteSnapshot: Sendable, Equatable {
  public let documentID: String
  public let sessionID: UUID
  public let generation: UInt64
  public let source: String
  public let headingOffsets: [Int]

  public init(
    documentID: String, sessionID: UUID, generation: UInt64, source: String,
    headingOffsets: [Int] = []
  ) {
    self.documentID = documentID
    self.sessionID = sessionID
    self.generation = generation
    self.source = source
    self.headingOffsets = headingOffsets
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
  public let snapshot: NoteSnapshot
  public let action: NoteIntelligenceAction
  public let instruction: String

  public init(snapshot: NoteSnapshot, action: NoteIntelligenceAction, instruction: String = "") {
    self.snapshot = snapshot
    self.action = action
    self.instruction = instruction
  }
}

public enum NoteIntelligenceError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case emptyInstruction
  case insufficientContext
  case invalidResponse
  case responseTooLarge
  case unverifiedQuotation
  case noEvidence
  case staleSnapshot
  case noApplicableChanges
  case invalidSelection
  case refused
  case rateLimited

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

  public init(
    purpose: Purpose, instruction: String, source: String, responseTokens: Int,
    evidenceOnly: Bool = false
  ) {
    self.purpose = purpose
    self.instruction = instruction
    self.source = source
    self.responseTokens = responseTokens
    self.evidenceOnly = evidenceOnly
  }
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
  func modelInfo() async throws -> NoteModelInfo
  func tokenCount(for pass: NoteModelPass) async throws -> Int
  func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate]
  func excerpts(for pass: NoteModelPass) async throws -> [String]
  func answer(
    for pass: NoteModelPass,
    onUpdate: @MainActor ([ModelAnswerPart]) -> Void
  ) async throws -> [ModelAnswerPart]
}
