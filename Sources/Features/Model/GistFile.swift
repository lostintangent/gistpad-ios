import Foundation
import Store

/// A file as it is on this iPhone: its gist, your draft once you've typed in it, and otherwise
/// GitHub's text.
public struct GistFile: Equatable, Sendable, Identifiable {
  /// The file on this iPhone, which keys its editor: its gist and filename, or a new gist's draft.
  /// It's fixed when the file opens, so a rename or a new gist's first publish keeps the editor.
  public let id: UUID
  public let accountID: UUID
  public var gist: Gist? { didSet { settle() } }
  public internal(set) var filename: String
  /// Your draft: stored from your first keystroke until GitHub has the text, or a new gist or day
  /// that's only started.
  public private(set) var draft: GistFileDraft?
  /// GitHub's text, for a file you haven't typed in.
  public private(set) var published: GitHubVersion?
  public var isDeletedOnGitHub: Bool

  public var text: String { draft?.text ?? published?.text ?? "" }
  public var gistID: String? { gist?.id ?? draft?.gistID }
  /// A new gist, a new day or an empty file, which opens for writing.
  public var isNew: Bool { (draft?.base ?? published) == nil || text.isEmpty }

  /// The draft your next keystroke saves: yours, or one starting from GitHub's text.
  public var nextDraft: GistFileDraft {
    draft
      ?? GistFileDraft(
        id: id, accountID: accountID, gistID: gistID, filename: filename,
        text: published?.text ?? "", base: published)
  }

  /// A file GitHub has, before you type in it.
  init(accountID: UUID, gist: Gist, filename: String, published: GitHubVersion) {
    id = GistFileDraft(accountID: accountID, gistID: gist.id, filename: filename).id
    self.accountID = accountID
    self.gist = gist
    self.filename = filename
    self.published = published
    isDeletedOnGitHub = false
  }

  /// A file with your draft: stored, or a new gist or day that's only started.
  init(draft: GistFileDraft, gist: Gist? = nil, isDeletedOnGitHub: Bool = false) {
    id = draft.id
    accountID = draft.accountID
    self.gist = gist
    filename = draft.filename
    self.draft = draft
    self.isDeletedOnGitHub = isDeletedOnGitHub
    settle()
  }

  /// Takes the store's word on your draft: kept, or let go once GitHub has the text.
  mutating func update(_ stored: GistFileDraft) {
    filename = stored.filename
    draft = stored
    published = nil
    settle()
  }

  /// Takes the name GitHub gave a file you haven't typed in.
  mutating func rename(_ filename: String) {
    self.filename = filename
    draft = draft?.renamed(filename)
  }

  /// A draft GitHub has goes once the file knows its gist, leaving GitHub's text.
  private mutating func settle() {
    guard let draft, draft.isPublished, let gist, gist.id == draft.gistID else { return }
    published = draft.base
    self.draft = nil
  }

  /// What reopens this file: its gist's file once it has one, or else its draft.
  var request: Opening.Request {
    if let gistID { .gist(id: gistID, filename: filename) } else { .draft(id: id) }
  }

  /// The file's own row in the library: its day, its gist, or its draft.
  var rowID: String {
    if let gist, gist.isDailyNote { "\(gist.id)/\(filename)" } else { gist?.id ?? id.uuidString }
  }

  func refersToSameFile(as other: GistFile) -> Bool {
    guard accountID == other.accountID, filename == other.filename else { return false }
    if id == other.id { return true }
    if let gistID { return gistID == other.gistID }
    return false
  }
}
