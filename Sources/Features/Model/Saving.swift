import Editor
import Foundation
import Store

// Every keystroke is saved on this iPhone first, so nothing you write waits on GitHub.

public enum EditError: LocalizedError {
  case localPersistenceFailed

  public var errorDescription: String? {
    String(
      localized:
        "Your latest changes couldn't be saved on this iPhone. Keep the editor open and retry the local save."
    )
  }
}

extension GistPadModel {
  /// Records a draft as this iPhone now has it: stored, or let go once GitHub has its text.
  private func record(_ draft: GistFileDraft) {
    localDraftRecords += 1
    localDrafts.removeAll { $0.id == draft.id }
    if !draft.isDisposable { localDrafts.append(draft) }
  }

  /// The file's stored draft, if you've typed in it since GitHub last had its text.
  public func current(_ draft: GistFileDraft) async throws -> GistFileDraft? {
    try await draftStore.current(draft)
  }

  /// GitHub's last text for the file, which a draft starts from when it's what you typed over.
  private func github(_ draft: GistFileDraft) -> GitHubVersion? {
    guard account?.id == draft.accountID, let gistID = draft.gistID else { return nil }
    return gistCache?.version(of: draft.filename, gistID: gistID)
  }

  /// Saves your typing over `draft` on this iPhone.
  func save(_ draft: GistFileDraft, text: String) async throws -> GistFileDraft {
    let saved = try await draftStore.save(draft, text: text, github: github(draft))
    if account?.id == draft.accountID {
      record(saved)
      if saved.isDisposable { projectLibrary() } else { updateLibraryExcerpt(for: saved) }
      updateToday()
    }
    return saved
  }

  /// Adds to a file from outside the app, such as Add to Today, and saves it on this iPhone.
  public func apply(_ edit: DraftEdit) async throws -> GistFileDraft {
    let applied = try await draftStore.apply(edit, github: github(edit.draft))
    if account?.id == applied.accountID {
      record(applied)
      updateLibraryExcerpt(for: applied)
      updateToday()
    }
    return applied
  }

  /// Stores a new gist you named outside the app, such as in Shortcuts, before it has any edits.
  public func createGist(named name: String, text: String? = nil) async throws -> GistFileDraft {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    return try await keep(GistFileDraft(accountID: account.id, newGistName: name, content: text))
  }

  /// Stores a note before you type in it.
  func keep(_ draft: GistFileDraft) async throws -> GistFileDraft {
    let kept = try await draftStore.keep(draft)
    if account?.id == draft.accountID {
      record(kept)
      projectLibrary()
      updateToday()
    }
    return kept
  }
}

extension GistFileEditor {
  /// Adds `edit` to the end of the open file, only while the editor shows the text it was made for.
  public func applyDurableEdit(
    _ edit: DraftEdit,
    commit: @MainActor () async throws -> GistFileDraft
  ) async throws {
    guard edit.draft.accountID == file.accountID, edit.draft.id == file.current.id else {
      throw AccountError.accountChanged
    }
    guard sourceEqual(edit.draft.text, editor.text) else { throw DraftError.changed }
    try await commitMutation(
      Edit(
        range: NSRange(location: editor.text.utf16.count, length: 0), expected: "",
        replacement: edit.text),
      expectedGeneration: editor.generation, commit: commit)
  }

  /// Commits a change you didn't type, such as GitHub's newer text, then shows it in the editor.
  /// Typing since `expectedGeneration` refuses it.
  func commitMutation(
    _ edit: Edit, expectedGeneration: UInt64,
    commit: @MainActor () async throws -> GistFileDraft
  ) async throws {
    guard canMutate else { throw Edit.MutationError.compositionActive }
    guard editor.generation == expectedGeneration else { throw DraftError.changed }
    let result = try edit.applying(to: editor.text)
    let changed = !result.utf8.elementsEqual(editor.text.utf8)
    let wasEditing = editor.isEditing
    isApplyingDurableEdit = true
    updateEditable()
    defer {
      isApplyingDurableEdit = false
      updateEditable()
      if wasEditing { editor.focus() }
    }
    guard await waitForLocalSave() else { throw EditError.localPersistenceFailed }
    guard editor.generation == expectedGeneration, editor.isSettled
    else { throw DraftError.changed }
    file.update(try await commit())
    if changed {
      try editor.apply(edit, generation: expectedGeneration)
    }
    guard await waitForLocalSave() else { throw EditError.localPersistenceFailed }
  }

  public func waitForLocalSave() async -> Bool {
    await persistence?.value ?? true
  }

  func persist(text: String, generation: UInt64) {
    let previous = persistence
    persistence = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return false }
      do {
        file.update(try await model.save(file.current, text: text))
        savedGeneration = generation
        failure = nil
        return true
      } catch {
        logger.error(
          "Local persistence failed: \(String(reflecting: type(of: error)), privacy: .public)")
        return false
      }
    }
  }
}
