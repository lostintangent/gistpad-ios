import GistPadEditor
import GistPadInterface
import GistPadSync
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct NotebookLayoutTests {
  @Test func modeChoicePersistsOnThisDeviceWithoutAffectingTheCompactFallback() throws {
    let name = "dev.gistpad.layout.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let layout = NotebookLayoutPreferences(defaults: defaults)
    #expect(layout.preferredMode == .split)
    #expect(layout.compactMode == .reading)
    layout.select(.source)
    layout.select(.split)
    let restored = NotebookLayoutPreferences(defaults: defaults)
    #expect(restored.preferredMode == .split)
    #expect(restored.compactMode == .source)
    restored.select(.reading)
    #expect(NotebookLayoutPreferences(defaults: defaults).preferredMode == .reading)
    #expect(restored.initialMode(isUnpublished: true) == .source)
  }

  @Test func splitEligibilityUsesTheDocumentWidthAndKeepsReadOnlyNotesReadOnly() throws {
    let name = "dev.gistpad.layout.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let layout = NotebookLayoutPreferences(defaults: defaults)
    for width: CGFloat in [0, 402, 639, .infinity, .nan] {
      #expect(!NotebookLayoutPreferences.allowsSplit(availableWidth: width))
    }
    #expect(NotebookLayoutPreferences.allowsSplit(availableWidth: 640))
    #expect(layout.presentedMode(
      availableWidth: 800, sessionMode: .reading, isEditing: false, canEdit: true) == .split)
    #expect(layout.presentedMode(
      availableWidth: 402, sessionMode: .reading, isEditing: true, canEdit: true) == .source)
    #expect(layout.presentedMode(
      availableWidth: 402, sessionMode: .reading, isEditing: false, canEdit: true) == .reading)
    #expect(layout.presentedMode(
      availableWidth: 800, sessionMode: .source, isEditing: true, canEdit: false) == .reading)
    #expect(layout.preferredMode == .split)
  }

  @Test func resizingTheProductionNoteKeepsOneEditorPreviewAndDurableDraft() async throws {
    let name = "dev.gistpad.layout.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let layout = NotebookLayoutPreferences(defaults: defaults)
    let store = try DraftStore.open(inMemory: true)
    let accountID = UUID()
    let original = (1...80).map { "Paragraph \($0): a retained native notebook." }.joined(separator: "\n\n")
    let draft = try await store.newDraft(accountID: accountID, githubUserID: 42, text: original)
    let session = DocumentSession(documentID: draft.id.uuidString, text: draft.text)
    var persistence: Task<DraftSnapshot, any Error>?
    session.onSourceChange = { text, generation in
      persistence = Task {
        try await store.persist(
          id: draft.id, accountID: accountID, text: text, generation: generation)
      }
    }
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(
      rootView: LayoutNoteFixture(session: session, layout: layout, width: 800))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(250))
    let editor = session.textView
    let preview = try #require(descendants(of: host.view).compactMap { $0 as? WKWebView }.first)
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: original.utf16.count / 2, length: 0)
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("Unsynced 日本語 👩🏽‍💻 ")
    editor.undoManager?.endUndoGrouping()
    let text = session.text
    let selection = editor.selectedRange
    for width: CGFloat in [402, 800, 639, 952, 402] {
      host.traitOverrides.horizontalSizeClass = width < 640 ? .compact : .regular
      host.rootView = LayoutNoteFixture(session: session, layout: layout, width: width)
      try await Task.sleep(for: .milliseconds(150))
      host.view.layoutIfNeeded()
      #expect(session.textView === editor)
      #expect(editor.window === window)
      #expect(editor.isFirstResponder)
      #expect(editor.selectedRange == selection)
      #expect(session.text.utf8.elementsEqual(text.utf8))
      #expect(descendants(of: host.view).compactMap { $0 as? WKWebView }.first === preview)
      #expect(layout.preferredMode == .split)
      let position = try #require(editor.selectedTextRange?.start)
      let caret = editor.caretRect(for: position)
      let viewport = editor.bounds.inset(by: editor.adjustedContentInset)
      #expect(caret.maxY >= viewport.minY && caret.minY <= viewport.maxY)
    }
    let write = try #require(persistence)
    let saved = try await write.value
    #expect(saved.text.utf8.elementsEqual(text.utf8))
    #expect(saved.gistID == nil)
    #expect(try await store.drafts(accountID: accountID).count == 1)
    editor.undoManager?.undo()
    #expect(session.text.utf8.elementsEqual(original.utf8))
    if let persistence { _ = try await persistence.value }
  }

  private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}

private struct LayoutNoteFixture: View {
  let session: DocumentSession
  let layout: NotebookLayoutPreferences
  let width: CGFloat

  var body: some View {
    NavigationStack {
      NoteScreen(
        document: .init(title: "Retained draft", files: [], selectedFileID: ""),
        mode: Binding(
          get: {
            layout.presentedMode(
              availableWidth: width, sessionMode: .source,
              isEditing: session.isEditing, canEdit: true)
          },
          set: { layout.select($0) }),
        saveState: .savedLocally,
        allowsSplit: NotebookLayoutPreferences.allowsSplit(availableWidth: width)
      ) {
        MarkdownEditorView(session: session)
      } preview: {
        SessionPreview(session: session)
      }
    }
    .frame(width: width)
  }
}
