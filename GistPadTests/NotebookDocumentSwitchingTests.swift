import GistPadEditor
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct NotebookDocumentSwitchingTests {
  @Test func changingDocumentsMountsTheCorrectRetainedTextViewAndIsolatesUndo() async throws {
    let daily = DocumentSession(documentID: "daily", text: "# Today's note\nDaily source")
    let note = DocumentSession(documentID: "another-gist", text: "# Another gist\nIts raw source")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: MarkdownEditorView(session: daily))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(150))
    let dailyView = daily.textView
    let noteView = note.textView
    dailyView.becomeFirstResponder()
    dailyView.selectedRange = NSRange(location: 0, length: 0)
    dailyView.undoManager?.beginUndoGrouping()
    dailyView.insertText("Daily edit: ")
    dailyView.undoManager?.endUndoGrouping()
    let dailyText = dailyView.text
    let dailySelection = dailyView.selectedRange

    host.rootView = MarkdownEditorView(session: note)
    try await Task.sleep(for: .milliseconds(150))
    #expect(noteView.window === window)
    #expect(dailyView.window == nil)
    #expect(noteView.text == "# Another gist\nIts raw source")
    noteView.becomeFirstResponder()
    noteView.selectedRange = NSRange(location: 3, length: 0)
    noteView.undoManager?.beginUndoGrouping()
    noteView.insertText("Private ")
    noteView.undoManager?.endUndoGrouping()
    let noteText = noteView.text
    let noteSelection = noteView.selectedRange

    for session in [daily, note, daily, note] {
      host.rootView = MarkdownEditorView(session: session)
      try await Task.sleep(for: .milliseconds(100))
      #expect(session.textView.window === window)
      #expect(daily.textView === dailyView)
      #expect(note.textView === noteView)
      #expect(dailyView.text == dailyText)
      #expect(noteView.text == noteText)
      #expect(dailyView.selectedRange == dailySelection)
      #expect(noteView.selectedRange == noteSelection)
    }
    noteView.undoManager?.undo()
    #expect(noteView.text == "# Another gist\nIts raw source")
    #expect(dailyView.text == dailyText)
    host.rootView = MarkdownEditorView(session: daily)
    try await Task.sleep(for: .milliseconds(100))
    dailyView.undoManager?.undo()
    #expect(dailyView.text == "# Today's note\nDaily source")
  }
}
