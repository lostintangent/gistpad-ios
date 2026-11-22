import Editor
import Intelligence
import Model
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class IntelligencePresentation {
  var target: Target?
  private var retainedTarget: Target?

  /// Opens Intelligence on the file. A passage the sheet shows opens in the editor once it closes.
  func present(
    _ fileEditor: GistFileEditor, model: GistPadModel,
    showEditor: @escaping @MainActor () -> Void
  ) {
    let editor = fileEditor.editor
    guard editor.isSettled else {
      model.alertMessage = String(
        localized: "Finish typing or wait for Writing Tools, then try again.")
      return
    }
    present(editor: editor, title: fileEditor.details.title) { range in
      guard fileEditor.details.isOwned else {
        model.alertMessage = String(
          localized: "This gist is read-only, so this passage can't open in Edit.")
        return
      }
      let generation = editor.generation
      showEditor()
      fileEditor.mode = .edit
      Task { @MainActor in
        await Task.yield()
        guard editor.generation == generation else {
          model.alertMessage = String(localized: "This passage is no longer in the file.")
          return
        }
        editor.select(range)
      }
    }
  }

  func present(
    editor: Editor, title: String,
    revealSource: @escaping @MainActor (NSRange) -> Void
  ) {
    let target = Target(editor: editor, title: title, revealSource: revealSource)
    retainedTarget = target
    editor.endEditing()
    self.target = target
  }

  func dismissed() {
    guard let target = retainedTarget else { return }
    retainedTarget = nil
    if let passage = target.passage {
      target.revealSource(passage)
      return
    }
    if target.wasEditing { target.editor.focus() }
  }

  @MainActor
  final class Target: Identifiable {
    let editor: Editor
    let title: String
    let revealSource: @MainActor (NSRange) -> Void
    let wasEditing: Bool
    var passage: NSRange?

    init(
      editor: Editor, title: String,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.editor = editor
      self.title = title
      self.revealSource = revealSource
      wasEditing = editor.isEditing
    }
  }
}

extension View {
  func intelligenceSheet(_ presentation: IntelligencePresentation) -> some View {
    modifier(IntelligenceSheetModifier(presentation: presentation))
  }
}

private struct IntelligenceSheetModifier: ViewModifier {
  @Bindable var presentation: IntelligencePresentation

  func body(content: Content) -> some View {
    content
      .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
        IntelligenceSheet(
          editor: target.editor, title: target.title,
          revealSource: { target.passage = $0 }
        )
      }
  }
}
