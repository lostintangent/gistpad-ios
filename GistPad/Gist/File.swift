import Foundation
import GistPadSync

struct File: Equatable, Sendable, Identifiable {
  let accountID: UUID
  var gist: Gist?
  var filename: String
  let text: String
  var draft: Draft?
  var isRecovery: Bool
  var libraryRowID: String?
  var editingRequestID: UUID?
  var revealsDetail = true
  var activationID: String { editingRequestID?.uuidString ?? id }
  let id: String

  init(accountID: UUID, gist: Gist, filename: String, text: String) {
    self.accountID = accountID
    self.gist = gist
    self.filename = filename
    self.text = text
    draft = nil
    isRecovery = false
    id = "\(accountID.uuidString)/\(gist.id)/\(filename)"
  }

  init(draft: Draft, gist: Gist? = nil, isRecovery: Bool = false) {
    accountID = draft.accountID
    self.gist = gist
    filename = draft.filename
    text = draft.text
    self.draft = draft
    self.isRecovery = isRecovery
    id = "\(draft.accountID.uuidString)/draft/\(draft.id.uuidString)"
  }

  var selection: FileReference {
    FileReference(gistID: gist?.id ?? draft?.gistID, filename: filename, draftID: draft?.id)
  }

  var rowID: String {
    if let libraryRowID { return libraryRowID }
    if let gist, gist.isDailyNote {
      return "\(gist.id)/\(filename)"
    }
    return gist?.id ?? draft?.id.uuidString ?? id
  }

  func refersToSameFile(as other: File) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if let draftID = draft?.id, draftID == other.draft?.id { return true }
    if let gistID = selection.gistID { return gistID == other.selection.gistID }
    return false
  }
}

/// A file on its way to the detail column, and why it couldn't open if it failed.
struct Opening: Equatable {
  enum Request: Equatable {
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

  let request: Request
  let rowID: String
  let title: String
  var failure: String?

  var filename: String? {
    switch request {
    case .gist(_, let filename, _): filename
    case .today(let target, _): target.filename
    case .draft, .new: nil
    }
  }
}
