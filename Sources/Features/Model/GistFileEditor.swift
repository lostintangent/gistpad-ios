import Editor
import Foundation
import Screens
import OSLog
import Observation
import Store

@MainActor
@Observable
public final class GistFileEditor {
  public internal(set) var file: GistFile
  public let editor: Editor
  var publishing: Task<Void, Never>?
  /// Why the last publish didn't land, until you type, publish again or reconnect GitHub.
  var failure: GitHubProblem?
  /// The editor's last generation saved on this iPhone.
  var savedGeneration: UInt64 = 0
  var isPerformingDestructiveAction = false
  var isApplyingDurableEdit = false
  public internal(set) var remoteInspectionProblem: GitHubProblem?
  public var mode: FileMode = .preview
  @ObservationIgnored let model: GistPadModel
  @ObservationIgnored var persistence: Task<Bool, Never>?
  @ObservationIgnored var autosaveTask: Task<Void, Never>?
  @ObservationIgnored var scheduledAutosave: AutosaveRequest?
  @ObservationIgnored var lastEditingRequestID: UUID?
  @ObservationIgnored let autosaveDelay: Duration
  @ObservationIgnored var isInspectingRemote = false
  /// When this note last read GitHub, so opening it again reads only once that's stale.
  @ObservationIgnored var refreshedAt: Date?
  @ObservationIgnored let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "File")

  init(file: GistFile, model: GistPadModel, autosaveDelay: Duration = .seconds(5)) {
    self.file = file
    self.model = model
    self.autosaveDelay = autosaveDelay
    editor = Editor(
      fileID: file.id, text: file.text,
      showsFrontMatter: model.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
    if isNew { mode = .edit }
    updateEditable()
    applyWritingPreferences()
    editor.onEdit = { [weak self] text, generation in
      self?.persist(text: text, generation: generation)
    }
    observeAutosave()
  }

  /// A new gist, a new day or an empty file, which opens for writing.
  public var isNew: Bool { file.current.base == nil || file.text.isEmpty }

  /// The gist's header and actions, always current with the library.
  public var details: GistDetails { model.details(for: file) }

  /// Where this note stands with GitHub: read-only for a recovery copy, publishing while a publish
  /// runs, a conflict until you choose, then why the last publish failed, and otherwise whether
  /// GitHub has your text.
  public var status: PublishStatus {
    if file.isDeletedOnGitHub { return .failed(.rejected) }
    if isPublishing { return .publishing }
    if file.draft?.conflict != nil { return .conflict }
    if let failure { return .failed(failure) }
    return file.current.isPublished && !hasUnpublishedChanges ? .published : .unpublished
  }

  /// Whether you've written anything GitHub doesn't have, including typing still saving.
  var hasUnpublishedChanges: Bool {
    file.draft != nil || editor.generation != savedGeneration
  }

  public var canMutate: Bool {
    details.access.canEdit && editor.isSettled
      && !isPerformingDestructiveAction
      && !isApplyingDurableEdit
  }

  /// Brings the note's name and gist up to date after a change. A file GitHub renamed before you
  /// typed in it takes `filename`.
  func refreshMetadata(gist: Gist? = nil, filename: String? = nil) async throws {
    if let stored = try await model.current(file.current) {
      file.update(stored)
    } else if let filename {
      file.update(unedited: file.current.renamed(filename))
    }
    if let gist { file.gist = gist }
    updateEditable()
    applyWritingPreferences()
  }

  /// You can type in your own gists, except while a change is landing in the note.
  func updateEditable() {
    editor.isEditable =
      details.access.canEdit && !isPerformingDestructiveAction && !isApplyingDurableEdit
  }

  private func applyWritingPreferences() {
    editor.isSpellCheckingEnabled =
      model.account?.preferences.booleanValue(.isSpellcheckEnabled) ?? true
    editor.setShowsFrontMatter(
      model.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
  }

  /// Takes a publish's or read's result once your typing has saved. A keystroke during it may have
  /// stored newer text, which the store has.
  func adopt(_ result: GistFileDraft) async {
    _ = await waitForLocalSave()
    file.update((try? await model.current(result)) ?? result)
  }
}
