import GistPadEditor
import GistPadInterface
import GistPadSync
import OSLog
import Observation

@MainActor
@Observable
final class NotebookSessionController {
  let document: NotebookDocument
  let session: DocumentSession
  private(set) var draft: DraftSnapshot
  private(set) var saveState: NoteSaveState
  private(set) var isPublishing = false
  var mode: NoteMode = .reading
  @ObservationIgnored private let notebook: NotebookModel
  @ObservationIgnored private var persistence: Task<Bool, Never>?
  @ObservationIgnored private let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Document")

  init(document: NotebookDocument, draft: DraftSnapshot, notebook: NotebookModel) {
    self.document = document
    self.draft = draft
    self.notebook = notebook
    session = DocumentSession(
      documentID: document.id, text: draft.text, generation: draft.generation)
    saveState = NotebookModel.interfaceSaveState(draft.state)
    session.textView.isEditable = document.chrome.access.canEdit
    session.onSourceChange = { [weak self] text, generation in
      self?.persist(text: text, generation: generation)
    }
  }

  var canMutate: Bool {
    document.chrome.access.canEdit && !session.isComposing && !session.writingToolsActive
  }

  func retryLocalSave() {
    persist(text: session.text, generation: session.generation)
  }

  func didReconnect() {
    if saveState == .reconnectRequired { saveState = .savedLocally }
  }

  func publish() async {
    guard canMutate, !isPublishing else { return }
    isPublishing = true
    defer { isPublishing = false }
    if let persistence, !(await persistence.value) { return }
    guard canMutate else { return }
    saveState = .savingToGitHub
    do {
      let saved = try await notebook.publish(draftID: draft.id, accountID: draft.accountID)
      draft = saved
      saveState =
        session.generation == saved.generation
        ? NotebookModel.interfaceSaveState(saved.state) : .unsaved
    } catch {
      logger.error(
        "Publishing failed: \(String(reflecting: type(of: error)), privacy: .public)")
      if error is AccountError {
        saveState = .reconnectRequired
      } else if let failure = error as? DraftError, failure == .readOnly {
        saveState = .publicationBlocked(
          message: String(localized: "This account no longer has permission to edit the gist."))
      } else if let failure = error as? GitHubClientError {
        switch failure {
        case .http(let status, _) where status == 401:
          saveState = .reconnectRequired
        case .incompleteGist, .fileTooLarge:
          saveState = .publicationBlocked(message: NotebookModel.message(for: failure))
        default:
          saveState = .cloudFailure(message: NotebookModel.message(for: failure))
        }
      } else {
        saveState = .cloudFailure(message: NotebookModel.message(for: error))
      }
    }
  }

  func waitForLocalSave() async -> Bool {
    if let persistence { return await persistence.value }
    return true
  }

  private func persist(text: String, generation: UInt64) {
    saveState = .unsaved
    let previous = persistence
    let draftID = draft.id
    let accountID = draft.accountID
    persistence = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      do {
        let saved = try await notebook.persist(
          draftID: draftID, accountID: accountID, text: text, generation: generation)
        draft = saved
        if session.generation == saved.generation {
          saveState = NotebookModel.interfaceSaveState(saved.state)
        }
        return true
      } catch {
        logger.error(
          "Local persistence failed: \(String(reflecting: type(of: error)), privacy: .public)")
        if session.generation == generation {
          saveState = .localFailure(
            message: String(
              localized:
                "Your latest changes are still in the editor. Try saving on this iPhone again before closing it."
            ))
        }
        return false
      }
    }
  }
}
