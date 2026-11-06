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
  private func record(_ draft: Draft) {
    localDraftRecords += 1
    localDrafts.removeAll { $0.id == draft.id }
    if draft.isSaved { localDrafts.append(draft) }
  }

  /// The draft as this iPhone has it now, stored or not.
  func current(_ draft: Draft) async throws -> Draft {
    try await sync.current(draft)
  }

  /// Saves your typing on this iPhone.
  func save(_ draft: Draft, text: String, generation: UInt64) async throws -> Draft {
    let saved = try await sync.save(draft, text: text, generation: generation)
    if account?.id == draft.accountID {
      record(saved)
      if saved.isSaved { updateLibraryExcerpt(for: saved) } else { projectLibrary() }
      updateToday()
    }
    return saved
  }

  /// Stores a note before you type in it.
  func keep(_ draft: Draft) async throws -> Draft {
    let kept = try await sync.keep(draft)
    if account?.id == draft.accountID {
      record(kept)
      projectLibrary()
      updateToday()
    }
    return kept
  }
}

extension GistFileEditor {
  public func applyDurableEdit(
    _ edit: DraftEdit,
    commit: @MainActor () async throws -> Draft
  ) async throws {
    guard edit.draft.accountID == draft.accountID, edit.draft.id == draft.id else {
      throw AccountError.accountChanged
    }
    try await commitMutation(
      Edit(
        range: NSRange(location: editor.text.utf16.count, length: 0), expected: "",
        replacement: edit.text),
      expectedGeneration: edit.draft.generation, commit: commit)
  }

  func commitMutation(
    _ edit: Edit, expectedGeneration: UInt64,
    commit: @MainActor () async throws -> Draft
  ) async throws {
    guard canMutate else { throw Edit.MutationError.compositionActive }
    guard editor.generation == expectedGeneration else { throw DraftError.staleGeneration }
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
    else { throw DraftError.staleGeneration }
    let committed = try await commit()
    if changed {
      try editor.apply(edit, generation: expectedGeneration)
    }
    adopt(committed)
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
        draft = try await model.save(draft, text: text, generation: generation)
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
