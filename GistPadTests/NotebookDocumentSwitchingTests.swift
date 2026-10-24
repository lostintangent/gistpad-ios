import GistPadEditor
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct NotebookDocumentSwitchingTests {
  @Test func anOutgoingHostCannotDetachTheRetainedEditorFromItsNewHost() async throws {
    let session = DocumentSession(documentID: "retained", text: "# Still visible\nA retained source.")
    let other = DocumentSession(documentID: "other", text: "# A different source")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    let outgoing = UIHostingController(rootView: MarkdownEditorView(session: session))
    root.addChild(outgoing)
    outgoing.view.frame = root.view.bounds
    outgoing.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.view.addSubview(outgoing.view)
    outgoing.didMove(toParent: root)
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await Task.sleep(for: .milliseconds(150))
    try #require(session.textView.isDescendant(of: outgoing.view))

    let incoming = UIHostingController(rootView: MarkdownEditorView(session: session))
    root.addChild(incoming)
    incoming.view.frame = root.view.bounds
    incoming.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.view.addSubview(incoming.view)
    incoming.didMove(toParent: root)
    try await Task.sleep(for: .milliseconds(150))
    try #require(session.textView.isDescendant(of: incoming.view))

    outgoing.rootView = MarkdownEditorView(session: other)
    outgoing.view.setNeedsLayout()
    outgoing.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    outgoing.willMove(toParent: nil)
    outgoing.view.removeFromSuperview()
    outgoing.removeFromParent()
    try await Task.sleep(for: .milliseconds(150))
    #expect(session.textView.window === window)
    #expect(session.textView.isDescendant(of: incoming.view))
    #expect(session.textView.text == "# Still visible\nA retained source.")
    #expect(session.generation == 0)
    Attachment.record(
      UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }, named: "retained-editor-after-outgoing-host-removal.png", as: .png)
  }

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
