import GistPadAppearance
import GistPadEditor
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class NotebookIntelligencePresentation {
  var target: Target?
  var errorMessage: String?
  private var retainedTarget: Target?

  func present(
    session: DocumentSession, title: String, filename: String,
    isCurrent: @escaping @MainActor () -> Bool,
    revealSource: @escaping @MainActor (NSRange) -> Void
  ) {
    guard isCurrent() else {
      errorMessage = String(localized: "The note changed. Open Intelligence again.")
      return
    }
    let target = Target(
      session: session, title: title, filename: filename,
      isCurrent: isCurrent, revealSource: revealSource)
    retainedTarget = target
    session.textView.resignFirstResponder()
    self.target = target
  }

  func dismissed() {
    guard let target = retainedTarget else { return }
    retainedTarget = nil
    guard target.isCurrent() else { return }
    if let reference = target.reference {
      guard target.session.generation == reference.generation else {
        errorMessage = String(
          localized: "The note changed. Open the reference from a fresh answer.")
        return
      }
      target.revealSource(reference.range)
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
    let filename: String
    let isCurrent: @MainActor () -> Bool
    let revealSource: @MainActor (NSRange) -> Void
    let generation: UInt64
    let selection: NSRange
    let offset: CGPoint
    let wasEditing: Bool
    struct Reference {
      let range: NSRange
      let generation: UInt64
    }

    var reference: Reference?

    init(
      session: DocumentSession, title: String, filename: String,
      isCurrent: @escaping @MainActor () -> Bool,
      revealSource: @escaping @MainActor (NSRange) -> Void
    ) {
      self.session = session
      self.title = title
      self.filename = filename
      self.isCurrent = isCurrent
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
          session: target.session, title: target.title, filename: target.filename,
          isCurrent: target.isCurrent,
          revealSource: {
            target.reference = .init(range: $0, generation: target.session.generation)
          }
        )
        .environment(\.personalAccent, personalAccent)
      }
      .onChange(of: presentation.target.map { $0.isCurrent() } ?? true) { _, current in
        if !current { presentation.target = nil }
      }
      .alert(
        String(localized: "Couldn't Complete Action"),
        isPresented: Binding(
          get: { presentation.errorMessage != nil },
          set: { if !$0 { presentation.errorMessage = nil } })
      ) {
        Button(String(localized: "OK"), role: .cancel) { presentation.errorMessage = nil }
      } message: {
        Text(presentation.errorMessage ?? "")
      }
  }
}
