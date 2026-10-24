import Foundation
import OSLog

@MainActor
final class NoteAttemptDiagnostics {
  struct Pass: Codable {
    let phase: String
    let schema: String
    let promptTokens: Int
    let responseTokenLimit: Int
  }

  struct Record: Codable {
    let id: UUID
    let action: String
    let requestedSchema: String
    let startedAt: Date
    var finishedAt: Date?
    var availability = "notChecked"
    var modelVariant: String?
    var contextSize: Int?
    var passes: [Pass] = []
    var responseLength = 0
    var errorType: String?
    var modelError: String?
    var outcome: String?
  }

  private(set) var record: Record
  private let directory: URL
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Intelligence")

  init(id: UUID, action: NoteIntelligenceAction, directory: URL? = nil) {
    let schema =
      switch action {
      case .ask: "answer-v2"
      case .edit: "edit-operations-v1"
      case .review: "review-replacements-v1"
      }
    record = Record(id: id, action: action.rawValue, requestedSchema: schema, startedAt: Date())
    self.directory =
      directory
      ?? URL.applicationSupportDirectory.appending(
        path: "IntelligenceDiagnostics", directoryHint: .isDirectory)
    persist()
  }

  func availability(_ value: String, info: NoteModelInfo? = nil) {
    record.availability = value
    record.modelVariant = info?.variant
    record.contextSize = info?.contextSize
    persist()
  }

  func measured(_ pass: NoteModelPass, tokens: Int, schema: String) {
    record.passes.append(
      Pass(
        phase: pass.purpose.rawValue, schema: schema, promptTokens: tokens,
        responseTokenLimit: pass.responseTokens))
    persist()
  }

  func response(length: Int) {
    record.responseLength = length
    record.errorType = nil
    record.modelError = nil
  }

  func failed(_ error: any Error, modelError: String? = nil) {
    record.errorType = String(reflecting: type(of: error))
    record.modelError = modelError
    persist()
  }

  func finish(errorCode: String?, errorType: String? = nil) {
    record.finishedAt = Date()
    if record.errorType == nil { record.errorType = errorType }
    if errorCode == nil {
      record.errorType = nil
      record.modelError = nil
    }
    record.outcome = errorCode ?? "success"
    persist()
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      try encoder.encode(record).write(
        to: directory.appending(path: "\(record.id.uuidString).json"), options: .atomic)
    } catch {
      logger.error(
        "request=\(self.record.id.uuidString, privacy: .public) diagnosticsWriteFailed type=\(String(reflecting: type(of: error)), privacy: .public)"
      )
    }
  }
}
