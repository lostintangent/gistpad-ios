import Foundation
import Model
import Screens

extension GistActions {
  /// The open file's verbs, run by the model. The root view passes how to present a sheet or
  /// Intelligence, and anything that opens over the file closes Comments first.
  init(
    _ fileEditor: GistFileEditor, model: GistPadModel, comments: CommentsPresentation,
    undoManager: UndoManager?, present: @escaping (RootView.Sheet) -> Void,
    intelligence: @escaping () -> Void
  ) {
    var actions = GistActions()
    if CommentsPresentation.supports(fileEditor.file) {
      actions.comments = {
        if comments.isPresented {
          comments.hide()
        } else {
          comments.open(for: fileEditor)
        }
      }
    }
    actions.reviewChanges = {
      guard let review = fileEditor.file.draft, review.conflict != nil else { return }
      present(.review(.init(fileEditor: fileEditor, review: review)))
    }
    actions.reconnect = { Task { await model.reconnect() } }
    let rename = { (kind: RenameTarget.Kind) in
      present(.rename(
        RenameTarget(draft: fileEditor.file.nextDraft, title: fileEditor.details.title, kind: kind)))
    }
    if let gistID = fileEditor.file.gist?.id {
      actions.selectFile = { filename in
        Task { await model.open(.gist(id: gistID, filename: filename)) }
      }
      actions.tags = { present(.tags(TagTarget(fileEditor, gistID: gistID, model: model))) }
      if !fileEditor.file.isDeletedOnGitHub {
        actions.togglePin = {
          let pinned = !fileEditor.details.isPinned
          model.run {
            try await model.updatePreferences([.setPinned(gistID: gistID, pinned: pinned)])
          }
        }
        actions.toggleStar = {
          let starred = !fileEditor.details.isStarred
          model.run { try await model.setStarred(starred, gistID: gistID) }
        }
        if fileEditor.details.isOwned {
          actions.toggleArchive = {
            model.setArchived(
              !fileEditor.details.isArchived, gistID: gistID, undoManager: undoManager)
          }
          actions.addFile = { rename(.addFile) }
          actions.renameFile = { rename(.filename) }
        }
      }
    }
    if fileEditor.details.isOwned, !fileEditor.file.isDeletedOnGitHub {
      actions.rename = { rename(.title) }
    }
    if fileEditor.deletion != nil {
      actions.delete = {
        // Read at confirmation, so a file that published meanwhile deletes from GitHub.
        guard let deletion = fileEditor.deletion else { return }
        model.run { try await model.delete(deletion) }
      }
    }
    actions.find = {
      fileEditor.mode = .edit
      fileEditor.editor.find(replacing: true)
    }
    let afterCommentsClose = { (action: @escaping () -> Void) in
      { comments.performAfterClosing(action) }
    }
    actions.intelligence = afterCommentsClose(intelligence)
    actions.tags = actions.tags.map(afterCommentsClose)
    actions.rename = actions.rename.map(afterCommentsClose)
    actions.renameFile = actions.renameFile.map(afterCommentsClose)
    actions.addFile = actions.addFile.map(afterCommentsClose)
    actions.find = afterCommentsClose(actions.find)
    actions.reviewChanges = afterCommentsClose(actions.reviewChanges)
    actions.delete = actions.delete.map(afterCommentsClose)
    self = actions
  }
}

extension RenameSheet {
  /// Saves the new title or filename, or adds the file, through the model.
  init(_ target: RenameTarget, model: GistPadModel) {
    self.init(target) { value in
      let draft = target.draft
      switch target.kind {
      case .title:
        try await model.rename(draft, to: value)
      case .filename:
        try await model.renameFile(draft, to: value)
      case .addFile:
        guard let gistID = draft.gistID else { throw ChangeError.publicationInProgress }
        try await model.addFile(named: value, to: gistID)
      }
    }
  }
}
