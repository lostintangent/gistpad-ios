import GistPadAccent
import GistPadEditor
import GistPadIntelligence
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class NotebookIntelligencePresentation {
  var target: Target?
  private var retainedTarget: Target?

  func present(
    session: Editor, title: String,
    revealSource: @escaping @MainActor (NSRange) -> Void
  ) {
    let target = Target(session: session, title: title, revealSource: revealSource)
    retainedTarget = target
    session.textView.resignFirstResponder()
    self.target = target
  }

  func dismissed() {
    guard let target = retainedTarget else { return }
    retainedTarget = nil
    if let reference = target.reference {
      target.revealSource(reference)
      return
    }
    let session = target.session
    let view = session.textView
    if target.wasEditing, session.canFormat, view.window != nil {
      if !view.becomeFirstResponder() {
        session.inputError = String(localized: "Tap the note to resume writing.")
      }
    }
  }

  @MainActor
  final class Target: Identifiable {
    let id = UUID()
    let session: Editor
    let title: String
    let revealSource: @MainActor (NSRange) -> Void
    let wasEditing: Bool
    var reference: NSRange?

    init(
      session: Editor, title: String,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.session = session
      self.title = title
      self.revealSource = revealSource
      wasEditing = session.textView.isFirstResponder
    }
  }
}

extension View {
  func notebookIntelligence(_ presentation: NotebookIntelligencePresentation) -> some View {
    modifier(NotebookIntelligenceModifier(presentation: presentation))
  }
}

private struct NotebookIntelligenceModifier: ViewModifier {
  @Bindable var presentation: NotebookIntelligencePresentation
  @Environment(\.accent) private var accent

  func body(content: Content) -> some View {
    content
      .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
        NoteIntelligenceSheet(
          session: target.session, title: target.title,
          revealSource: { target.reference = $0 }
        )
        .environment(\.accent, accent)
      }
  }
}
