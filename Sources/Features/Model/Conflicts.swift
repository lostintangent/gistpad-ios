import Editor
import Foundation
import Store

// When GitHub changed a note you also edited, you see both versions and choose what to keep.

extension GistFileEditor {
  /// Settles the conflict you reviewed in `reviewed` with `text`, which then starts from GitHub's
  /// newer version, and publishes it if you asked. It lands only while the draft is as you
  /// reviewed it.
  public func resolveConflict(_ reviewed: GistFileDraft, text: String, publishes: Bool) async throws {
    guard reviewed.conflict != nil, file.draft == reviewed, sourceEqual(reviewed.text, editor.text)
    else { throw ChangeError.staleReview }
    try await commitMutation(
      Edit(
        range: NSRange(location: 0, length: editor.text.utf16.count),
        expected: editor.text, replacement: text),
      expectedGeneration: editor.generation
    ) {
      let store = model.draftStore
      let resolved = try await model.serially {
        do { return try await store.resolveConflict(reviewed, text: text) }
        catch DraftError.changed { throw ChangeError.staleReview }
      }
      try await model.reloadLocalState(accountID: resolved.accountID)
      return resolved
    }
    if publishes { await publish() }
  }
}
