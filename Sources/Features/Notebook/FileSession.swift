import Editor
import Foundation
import Interface
import OSLog
import Observation
import Sync

@MainActor
@Observable
public final class FileSession {
  public internal(set) var file: File
  public let editor: Editor
  public internal(set) var draft: Draft
  var publishing: Task<Void, Never>?
  /// Why the last publish didn't land, until you type, publish again or reconnect GitHub.
  var failure: PublishState?
  var isPerformingDestructiveAction = false
  var isApplyingDurableEdit = false
  public internal(set) var remoteInspectionProblem: RemoteReadProblem?
  public var mode: FileMode = .preview
  @ObservationIgnored let library: Library
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

  init(file: File, library: Library, autosaveDelay: Duration = .seconds(5)) {
    self.file = file
    draft = file.draft
    self.library = library
    self.autosaveDelay = autosaveDelay
    editor = Editor(
      fileID: file.id, text: file.draft.text, generation: file.draft.generation,
      showsFrontMatter: library.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
    if isNew { mode = .edit }
    updateEditable()
    applyWritingPreferences()
    editor.onEdit = { [weak self] text, generation in
      self?.persist(text: text, generation: generation)
    }
    observeAutosave()
  }

  /// A new gist, a new day or an empty file, which opens for writing.
  public var isNew: Bool { draft.base == nil || draft.text.isEmpty }

  /// The gist's header and actions, always current with the library.
  public var details: GistDetails { library.details(for: file) }

  /// Where this note stands with GitHub: read-only for a recovery copy, Saving while a publish
  /// runs, and otherwise the draft's state.
  public var saveState: PublishState {
    if file.isRecovery { return .failed(.readOnly) }
    if isPublishing { return .savingToGitHub(generation: draft.generation) }
    if case .conflict = draft.state { return draft.state }
    return failure ?? draft.state
  }

  public var canMutate: Bool {
    details.access.canEdit && editor.isSettled
      && !isPerformingDestructiveAction
      && !isApplyingDurableEdit
  }

  /// Brings the note's name and gist up to date after a change. A file GitHub renamed before you
  /// typed in it takes `filename`.
  func refreshMetadata(gist: Gist? = nil, filename: String? = nil) async throws {
    adopt(try await library.current(draft))
    if !draft.isSaved, let filename { adopt(draft.renamed(filename)) }
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
      library.account?.preferences.booleanValue(.isSpellcheckEnabled) ?? true
    editor.setShowsFrontMatter(
      library.account?.preferences.booleanValue(.showFrontmatter, default: false) ?? false)
  }

  /// Takes the store's latest word on this draft. A read or publish that started before a keystroke
  /// can finish after that keystroke saves, and its older draft would make the edit look published.
  func adopt(_ stored: Draft) {
    if stored.generation >= draft.generation { draft = stored }
    file.draft = draft
  }
}
