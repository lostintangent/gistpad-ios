import Foundation
import Store

/// A file as it is on this iPhone: its gist, and your draft once you've typed in it, else the file
/// as you opened it.
public struct GistFile: Equatable, Sendable, Identifiable {
  public var gist: Gist?
  /// Your stored draft, from your first keystroke until GitHub has the text.
  public private(set) var draft: GistFileDraft?
  /// The file before you type: GitHub's text, or a new gist or day as it starts.
  public private(set) var unedited: GistFileDraft
  public var isDeletedOnGitHub: Bool
  var libraryRowID: String?
  var editingRequestID: UUID?
  public var revealsDetail = true
  /// The file's identity on this iPhone, from the draft it opened with, which keys its editor.
  public let draftID: UUID
  public var id: String { "\(accountID.uuidString)/draft/\(draftID.uuidString)" }

  /// The draft your next keystroke saves.
  public var current: GistFileDraft { draft ?? unedited }
  public var accountID: UUID { unedited.accountID }
  public var filename: String { current.filename }
  public var text: String { current.text }
  public var activationID: String { editingRequestID?.uuidString ?? id }

  /// A file you haven't typed in.
  init(unedited: GistFileDraft, gist: Gist? = nil) {
    self.unedited = unedited
    self.gist = gist
    isDeletedOnGitHub = false
    draftID = unedited.id
  }

  /// A file with your stored draft.
  init(draft: GistFileDraft, gist: Gist? = nil, isDeletedOnGitHub: Bool = false) {
    self.init(unedited: draft, gist: gist)
    self.draft = draft
    self.isDeletedOnGitHub = isDeletedOnGitHub
  }

  /// Takes the store's word on the draft: kept, or let go with nothing left to keep.
  mutating func update(_ stored: GistFileDraft) {
    if stored.isDisposable {
      draft = nil
      unedited = stored
    } else {
      draft = stored
    }
  }

  /// Takes the file as it is when nothing is stored for it.
  mutating func update(unedited: GistFileDraft) {
    draft = nil
    self.unedited = unedited
  }

  var gistID: String? { gist?.id ?? current.gistID }

  /// What reopens this file: its gist's file once it has one, or else its draft.
  var request: Opening.Request {
    if let gistID { .gist(id: gistID, filename: filename) } else { .draft(id: draftID) }
  }

  public var rowID: String {
    if let libraryRowID { return libraryRowID }
    if let gist, gist.isDailyNote {
      return "\(gist.id)/\(filename)"
    }
    return gist?.id ?? draftID.uuidString
  }

  func refersToSameFile(as other: GistFile) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if draftID == other.draftID { return true }
    if let gistID { return gistID == other.gistID }
    return false
  }
}
