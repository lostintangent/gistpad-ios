import Foundation
import Store

/// A note in the detail column: its draft, whether stored or just read, and the gist it's in.
public struct GistFile: Equatable, Sendable, Identifiable {
  public var draft: Draft
  public var gist: Gist?
  public var isRecovery: Bool
  var libraryRowID: String?
  var editingRequestID: UUID?
  public var revealsDetail = true
  public let id: String
  public var accountID: UUID { draft.accountID }
  public var filename: String { draft.filename }
  public var activationID: String { editingRequestID?.uuidString ?? id }

  init(draft: Draft, gist: Gist? = nil, isRecovery: Bool = false) {
    self.draft = draft
    self.gist = gist
    self.isRecovery = isRecovery
    id = "\(draft.accountID.uuidString)/draft/\(draft.id.uuidString)"
  }

  var gistID: String? { gist?.id ?? draft.gistID }

  /// What reopens this file: its gist's file once it has one, or else its draft.
  var request: Opening.Request {
    if let gistID { .gist(id: gistID, filename: filename) } else { .draft(id: draft.id) }
  }

  public var rowID: String {
    if let libraryRowID { return libraryRowID }
    if let gist, gist.isDailyNote {
      return "\(gist.id)/\(filename)"
    }
    return gist?.id ?? draft.id.uuidString
  }

  func refersToSameFile(as other: GistFile) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if draft.id == other.draft.id { return true }
    if let gistID { return gistID == other.gistID }
    return false
  }
}
