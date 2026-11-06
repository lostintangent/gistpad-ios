import Foundation
import Sync

/// A note in the detail column: its draft, whether stored or just read, and the gist it's in.
public struct File: Equatable, Sendable, Identifiable {
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

  var selection: FileReference {
    FileReference(gistID: gist?.id ?? draft.gistID, filename: filename, draftID: draft.id)
  }

  public var rowID: String {
    if let libraryRowID { return libraryRowID }
    if let gist, gist.isDailyNote {
      return "\(gist.id)/\(filename)"
    }
    return gist?.id ?? draft.id.uuidString
  }

  func refersToSameFile(as other: File) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if draft.id == other.draft.id { return true }
    if let gistID = selection.gistID { return gistID == other.selection.gistID }
    return false
  }
}
