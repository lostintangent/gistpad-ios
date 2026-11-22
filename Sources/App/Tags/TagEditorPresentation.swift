import Model
import Screens
import SwiftUI

/// The gist whose tags the sheet edits, and whether this account can change them.
struct TagTarget: Identifiable {
  var id: String { "\(accountID.uuidString)/\(gistID)" }
  let accountID: UUID
  let gistID: String
  let selected: Set<String>
  let canEdit: Bool

  @MainActor
  init(_ fileEditor: GistFileEditor, gistID: String, model: GistPadModel) {
    accountID = fileEditor.file.accountID
    self.gistID = gistID
    selected = Set(model.account?.preferences.gistTags[gistID] ?? [])
    canEdit = model.account?.id == accountID && !fileEditor.file.isDeletedOnGitHub
  }
}

extension TagEditor {
  init(_ target: TagTarget, model: GistPadModel) {
    self.init(
      gistID: target.gistID, tags: model.state.tags, selectedTagIDs: target.selected,
      save: target.canEdit ? model.updatePreferences : nil)
  }
}
