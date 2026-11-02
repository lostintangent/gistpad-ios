import GistPadAppearance
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
    session: DocumentSession, title: String,
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
    guard session.generation == target.generation else { return }
    view.selectedRange = target.selection
    view.layoutIfNeeded()
    let minimum = -view.adjustedContentInset.top
    let maximum = max(
      minimum, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    view.setContentOffset(
      CGPoint(x: target.offset.x, y: min(maximum, max(minimum, target.offset.y))), animated: false)
  }

  @MainActor
  final class Target: Identifiable {
    let id = UUID()
    let session: DocumentSession
    let title: String
    let revealSource: @MainActor (NSRange) -> Void
    let generation: UInt64
    let selection: NSRange
    let offset: CGPoint
    let wasEditing: Bool
    var reference: NSRange?

    init(
      session: DocumentSession, title: String,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.session = session
      self.title = title
      self.revealSource = revealSource
      generation = session.generation
      selection = session.textView.selectedRange
      offset = session.textView.contentOffset
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
  @Environment(\.personalAccent) private var personalAccent

  func body(content: Content) -> some View {
    content
      .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
        NoteIntelligenceSheet(
          session: target.session, title: target.title,
          revealSource: { target.reference = $0 }
        )
        .environment(\.personalAccent, personalAccent)
      }
  }
}
