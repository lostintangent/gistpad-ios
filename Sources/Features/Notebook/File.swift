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

/// A file on its way to the detail column, and why it couldn't open if it failed.
public struct Opening: Equatable {
  public enum Request: Equatable {
    case gist(id: String, filename: String? = nil, rowID: String? = nil)
    case draft(id: UUID, rowID: String? = nil)
    case today(DailyNote.Day = DailyNote.Day(), focusesEditor: Bool = true)
    case new

    /// Creating a gist or starting the day puts the caret in it.
    var focusesEditor: Bool {
      switch self {
      case .new: true
      case .today(_, let focusesEditor): focusesEditor
      case .gist, .draft: false
      }
    }

    /// The saved file this opens, so deleting it stops the opening.
    var selection: FileReference? {
      switch self {
      case .gist(let id, let filename, _): .init(gistID: id, filename: filename ?? "", draftID: nil)
      case .draft(let id, _): .init(gistID: nil, filename: "", draftID: id)
      case .today, .new: nil
      }
    }
  }

  public let request: Request
  public let rowID: String
  public let title: String
  public var failure: String?

  public var filename: String? {
    switch request {
    case .gist(_, let filename, _): filename
    case .today(let target, _): target.filename
    case .draft, .new: nil
    }
  }
}
