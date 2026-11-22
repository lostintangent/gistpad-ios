import Foundation
import Model
import Screens

extension LibraryActions {
  /// The Library's verbs, run by the model. The root view passes the ones that move navigation:
  /// opening a row or its comments, opening Today and showing Settings.
  init(
    model: GistPadModel, undoManager: UndoManager?,
    select: @escaping (String) -> Void, openComments: @escaping (String) -> Void,
    today: @escaping @MainActor () -> Void, settings: @escaping () -> Void
  ) {
    var actions = LibraryActions()
    actions.refresh = { await model.refresh() }
    actions.create = { Task { await model.open(.new) } }
    actions.today = today
    actions.select = select
    actions.openComments = openComments
    actions.account = settings
    actions.reconnect = { Task { await model.reconnect() } }
    actions.recoverStatus = {
      Task {
        if model.problem == .reconnect {
          await model.reconnect()
        } else {
          await model.refresh()
        }
      }
    }
    actions.togglePin = { rowID in
      guard let account = model.account, let id = model.gistID(forRow: rowID) else {
        model.alertMessage = String(localized: "Save this local draft to GitHub before pinning it.")
        return
      }
      let pinned = !account.preferences.pinnedGists.contains(id)
      model.run { try await model.updatePreferences([.setPinned(gistID: id, pinned: pinned)]) }
    }
    actions.toggleArchive = { rowID in
      guard let id = model.gistID(forRow: rowID),
        let gist = model.gistCache?.gists.first(where: { $0.id == id })
      else {
        model.alertMessage = String(
          localized: "A recovery or unpublished draft cannot be archived on GitHub.")
        return
      }
      model.setArchived(!gist.isArchived, gistID: id, undoManager: undoManager)
    }
    actions.delete = { rowID in
      guard let deletion = model.deletion(forRow: rowID) else { return }
      model.run { try await model.delete(deletion) }
    }
    self = actions
  }
}
