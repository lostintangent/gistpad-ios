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

  /// Opens Intelligence on the file. A reference the sheet returns opens in the editor once it closes.
  func present(
    _ fileEditor: GistFileEditor, model: GistPadModel,
    showEditor: @escaping @MainActor () -> Void
  ) {
    let editor = fileEditor.editor
    guard editor.isSettled else {
      model.alertMessage = String(
        localized: "Finish composition or Writing Tools before opening Intelligence.")
      return
    }
    present(editor: editor, title: fileEditor.details.title) { range in
      guard fileEditor.details.isOwned else {
        model.alertMessage = String(
          localized: "This gist is read-only, so the reference can't open in the editor.")
        return
      }
      let generation = editor.generation
      showEditor()
      fileEditor.mode = .edit
      Task { @MainActor in
        await Task.yield()
        guard editor.generation == generation else {
          model.alertMessage = String(localized: "This reference no longer matches the file.")
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
    if let reference = target.reference {
      target.revealSource(reference)
      return
    }
    if target.wasEditing { target.editor.focus() }
  }

  @MainActor
  final class Target: Identifiable {
    let id = UUID()
    let editor: Editor
    let title: String
    let revealSource: @MainActor (NSRange) -> Void
    let wasEditing: Bool
    var reference: NSRange?

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
          revealSource: { target.reference = $0 }
        )
      }
  }
}
