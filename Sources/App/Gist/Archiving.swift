import Foundation
import Model

extension GistPadModel {
  /// Archiving is absolute, so its undo is the opposite archive, registered with the scene so
  /// shake to undo and the undo gesture reverse it.
  func setArchived(_ archived: Bool, gistID: String, undoManager: UndoManager?) {
    run { try await self.setArchived(archived, gistID: gistID) }
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] model in
      model.setArchived(!archived, gistID: gistID, undoManager: undoManager)
    }
    undoManager?.setActionName(
      archived ? String(localized: "Archive") : String(localized: "Unarchive"))
  }
}
