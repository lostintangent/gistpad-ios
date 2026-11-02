import GistPadAccent
import GistPadEditor
import GistPadIntelligence
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class IntelligencePresentation {
  var target: Target?
  private var retainedTarget: Target?

  func present(
    editor: Editor, title: String,
    revealSource: @escaping @MainActor (NSRange) -> Void
  ) {
    let target = Target(editor: editor, title: title, revealSource: revealSource)
    retainedTarget = target
    editor.textView.resignFirstResponder()
    self.target = target
  }

  func dismissed() {
    guard let target = retainedTarget else { return }
    retainedTarget = nil
    if let reference = target.reference {
      target.revealSource(reference)
      return
    }
    let editor = target.editor
    let view = editor.textView
    if target.wasEditing, editor.canFormat, view.window != nil {
      if !view.becomeFirstResponder() {
        editor.inputError = String(localized: "Tap the file to resume writing.")
      }
    }
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
      wasEditing = editor.textView.isFirstResponder
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
  @Environment(\.accent) private var accent

  func body(content: Content) -> some View {
    content
      .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
        IntelligenceSheet(
          editor: target.editor, title: target.title,
          revealSource: { target.reference = $0 }
        )
        .environment(\.accent, accent)
      }
  }
}
