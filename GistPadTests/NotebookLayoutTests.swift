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
  @Test func libraryDisclosuresStartCollapsedAndRememberOnlyTheirOwnAccount() throws {
    let name = "dev.gistpad.layout.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let account = UUID()
    let otherAccount = UUID()
    let layout = NotebookLayoutPreferences(defaults: defaults)
    #expect(layout.expandedCollections(accountID: account).isEmpty)
    layout.setExpandedCollections([.gists, .dailyNotes, .archive], accountID: account)
    #expect(layout.expandedCollections(accountID: account) == [.dailyNotes, .archive])
    #expect(layout.expandedCollections(accountID: otherAccount).isEmpty)
    let restored = NotebookLayoutPreferences(defaults: defaults)
    #expect(restored.expandedCollections(accountID: account) == [.dailyNotes, .archive])
    restored.setExpandedCollections([.starred], accountID: otherAccount)
    restored.setExpandedCollections([], accountID: account)
    let relaunched = NotebookLayoutPreferences(defaults: defaults)
    #expect(relaunched.expandedCollections(accountID: account).isEmpty)
    #expect(relaunched.expandedCollections(accountID: otherAccount) == [.starred])
  }

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
    for width: CGFloat in [0, 402, 639, 640, .infinity, .nan] {
      #expect(!NotebookLayoutPreferences.allowsSplit(availableWidth: width))
    }
    #expect(NotebookLayoutPreferences.allowsSplit(availableWidth: 641))
    #expect(
      layout.presentedMode(
        availableWidth: 800, sessionMode: .reading, isEditing: false, canEdit: true) == .split)
    #expect(
      layout.presentedMode(
        availableWidth: 402, sessionMode: .reading, isEditing: true, canEdit: true) == .source)
    #expect(
      layout.presentedMode(
        availableWidth: 402, sessionMode: .reading, isEditing: false, canEdit: true) == .reading)
    #expect(
      layout.presentedMode(
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
    let original = (1...80).map { "Paragraph \($0): a retained native notebook." }.joined(
      separator: "\n\n")
    let draft = try await store.newDraft(accountID: accountID, githubUserID: 42, text: original)
    let session = Editor(fileID: draft.id.uuidString, text: draft.text)
    var persistence: Task<DraftSnapshot, any Error>?
    session.onEdit = { text, generation in
      persistence = Task {
        try await store.persist(
          id: draft.id, accountID: accountID, text: text, generation: generation)
      }
    }
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(
      rootView: LayoutNoteFixture(session: session, layout: layout, width: 382))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(250))
    let editor = session.textView
    let preview = try #require(descendants(of: host.view).compactMap { $0 as? WKWebView }.first)
    editor.selectedRange = NSRange(location: 0, length: 0)
    editor.scrollRangeToVisible(editor.selectedRange)
    editor.layoutIfNeeded()
    let initial = try recordCaretGeometry(editor, in: host.view, named: "initial-382")
    #expect(
      initial.caret.minY >= initial.viewport.minY && initial.caret.maxY <= initial.viewport.maxY,
      "The first source line must start below the actual navigation chrome.")
    editor.becomeFirstResponder()
    editor.selectedRange = NSRange(location: original.utf16.count / 2, length: 0)
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("Unsynced 日本語 👩🏽‍💻 ")
    editor.undoManager?.endUndoGrouping()
    let text = session.text
    let selection = editor.selectedRange
    try await Task.sleep(for: .milliseconds(350))
    host.view.layoutIfNeeded()
    if let manager = editor.textLayoutManager, let range = manager.textContentManager?.documentRange
    {
      manager.ensureLayout(for: range)
    }
    editor.layoutIfNeeded()
    editor.scrollRangeToVisible(selection)
    editor.layoutIfNeeded()
    let baseline = try recordCaretGeometry(editor, in: host.view, named: "baseline-382")
    try #require(
      baseline.caret.minY >= baseline.viewport.minY
        && baseline.caret.maxY <= baseline.viewport.maxY,
      "Establish a fully visible caret before testing resize continuity.")
    let widths: [CGFloat] = [402, 800, 640, 952, 402]
    for (index, width) in widths.enumerated() {
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
      let (caret, viewport) = try recordCaretGeometry(
        editor, in: host.view, named: "resize-\(index)-\(Int(width))")
      #expect(caret.minY >= viewport.minY - 1 && caret.maxY <= viewport.maxY + 1)
      #expect(caret.minX >= viewport.minX - 1 && caret.maxX <= viewport.maxX + 1)
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

  private func recordCaretGeometry(
    _ editor: UITextView, in root: UIView, named name: String
  ) throws -> (caret: CGRect, viewport: CGRect) {
    let position = try #require(editor.selectedTextRange?.start)
    let window = try #require(editor.window)
    let caret = editor.caretRect(for: position)
    let nativeViewport = editor.bounds.inset(by: editor.adjustedContentInset)
    var viewport = nativeViewport.intersection(
      editor.convert(window.bounds.inset(by: window.safeAreaInsets), from: window))
    let bars = descendants(of: root).compactMap { $0 as? UINavigationBar }
      .filter { !$0.isHidden && $0.alpha > 0 && $0.window === window }
      .map { editor.convert($0.bounds, from: $0) }
    for bar in bars where bar.intersects(viewport) {
      let top = min(viewport.maxY, max(viewport.minY, bar.maxY))
      viewport = CGRect(
        x: viewport.minX, y: top, width: viewport.width, height: viewport.maxY - top)
    }
    Attachment.record(
      """
      phase: \(name)
      editor frame in window: \(editor.convert(editor.bounds, to: window))
      window bounds: \(window.bounds), safe area: \(window.safeAreaInsets)
      bounds: \(editor.bounds), content size: \(editor.contentSize)
      content offset: \(editor.contentOffset), content inset: \(editor.contentInset)
      safe area: \(editor.safeAreaInsets), adjusted inset: \(editor.adjustedContentInset)
      inset adjustment policy: \(editor.contentInsetAdjustmentBehavior.rawValue)
      text container: \(editor.textContainer.size), text inset: \(editor.textContainerInset)
      native viewport: \(nativeViewport), navigation bars in editor: \(bars)
      unobscured viewport: \(viewport), caret: \(caret)
      selection: \(editor.selectedRange), first responder: \(editor.isFirstResponder)
      """,
      named: "caret-layout-\(name).txt")
    return (caret, viewport)
  }

  private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }
}

private struct LayoutNoteFixture: View {
  let session: Editor
  let layout: NotebookLayoutPreferences
  let width: CGFloat

  var body: some View {
    GeometryReader { _ in
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
          EditorView(session: session)
        } preview: {
          SessionPreview(session: session)
        }
      }
      .frame(width: width)
    }
  }
}
