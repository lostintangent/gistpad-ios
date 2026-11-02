import GistPadInterface
import SwiftUI
import Testing
import UIKit

@testable import GistPadEditor

@Suite(.serialized)
@MainActor
struct NotebookDocumentSwitchingTests {
  enum OwnerState: CaseIterable {
    case current, missing, detached
  }

  @Test(arguments: [false, true])
  func supersededContainersCannotReconfigureDetachOrReclaimTheEditor(composing: Bool) throws {
    let source = "# A retained source\nAn editable thought."
    let session = DocumentSession(documentID: "owned-source", text: source)
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let outgoing = SourceTextViewHost(session: session)
    outgoing.frame = fixture.root.view.bounds
    outgoing.configure { $0.isHidden = false }
    fixture.root.view.addSubview(outgoing)
    let editor = session.textView
    try #require(editor.becomeFirstResponder())
    editor.selectedRange = NSRange(location: 0, length: 0)
    if composing {
      editor.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
      try #require(editor.markedTextRange != nil)
    } else {
      editor.undoManager?.beginUndoGrouping()
      editor.insertText("An edit: ")
      editor.undoManager?.endUndoGrouping()
      try #require(editor.undoManager?.canUndo == true)
    }
    let text = editor.text
    let selection = editor.selectedRange
    let generation = session.generation
    let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
    let incoming = SourceTextViewHost(session: session)
    incoming.frame = fixture.root.view.bounds
    incoming.configure {
      $0.isHidden = false
      $0.inputAccessoryView = accessory
    }
    try #require(editor.superview === outgoing)
    fixture.root.view.addSubview(incoming)
    try #require(editor.superview === incoming)

    outgoing.configure {
      $0.isHidden = true
      $0.inputAccessoryView = nil
    }
    outgoing.setNeedsLayout()
    outgoing.layoutIfNeeded()
    outgoing.dismantle()
    outgoing.removeFromSuperview()
    incoming.layoutIfNeeded()

    #expect(editor.superview === incoming)
    #expect(editor.window === fixture.window)
    #expect(editor.frame == incoming.bounds)
    #expect(!editor.isHidden)
    #expect(editor.inputAccessoryView === accessory)
    #expect(editor.isFirstResponder)
    #expect(editor.text == text)
    #expect(editor.selectedRange == selection)
    #expect(session.generation == generation)
    #expect((editor.markedTextRange != nil) == composing)
    if !composing {
      editor.undoManager?.undo()
      #expect(editor.text == source)
    }
  }

  @Test(arguments: [false, true])
  func aReturningStaleHostCannotOrphanTheVisibleHost(dismantled: Bool) throws {
    let session = DocumentSession(documentID: "stale-return", text: "# Still visible")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let stale = SourceTextViewHost(session: session)
    let visible = SourceTextViewHost(session: session)
    let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
    stale.frame = fixture.root.view.bounds
    visible.frame = fixture.root.view.bounds
    stale.configure { $0.isHidden = true }
    visible.configure {
      $0.isHidden = false
      $0.inputAccessoryView = accessory
    }
    fixture.root.view.addSubview(stale)
    fixture.root.view.addSubview(visible)
    let editor = session.textView
    editor.selectedRange = NSRange(location: 3, length: 0)
    try #require(editor.superview === visible)

    stale.removeFromSuperview()
    fixture.root.view.addSubview(stale)
    #expect(editor.superview === visible)
    if dismantled {
      stale.dismantle()
    } else {
      stale.removeFromSuperview()
    }

    #expect(session.sourceHost === visible)
    #expect(editor.superview === visible)
    #expect(editor.window === fixture.window)
    #expect(!editor.isHidden)
    #expect(editor.inputAccessoryView === accessory)
    #expect(editor.selectedRange == NSRange(location: 3, length: 0))
    #expect(editor.text == "# Still visible")
    #expect(session.generation == 0)
    stale.setNeedsLayout()
    stale.layoutIfNeeded()
    #expect(editor.superview === visible)
  }

  @Test(arguments: [false, true])
  func anOwnerLeavingOrDismantlingImmediatelyReturnsTheEditorToThePreviousLiveHost(
    dismantled: Bool
  ) throws {
    let session = DocumentSession(documentID: "owner-left", text: "# Still attached")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let previous = SourceTextViewHost(session: session)
    let owner = SourceTextViewHost(session: session)
    previous.frame = fixture.root.view.bounds
    owner.frame = fixture.root.view.bounds
    fixture.root.view.addSubview(previous)
    fixture.root.view.addSubview(owner)
    let editor = session.textView
    try #require(editor.superview === owner)
    if dismantled {
      owner.dismantle()
    } else {
      owner.removeFromSuperview()
    }
    #expect(session.sourceHost === previous)
    #expect(editor.superview === previous)
    #expect(editor.window === fixture.window)
    #expect(editor.text == "# Still attached")
    #expect(session.generation == 0)
  }

  @Test(arguments: OwnerState.allCases)
  func anInWindowContainerRepairsMissingDetachedAndCurrentOwnership(owner: OwnerState) throws {
    let session = DocumentSession(documentID: "reattached", text: "# Still here")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let host = SourceTextViewHost(session: session)
    host.frame = fixture.root.view.bounds
    fixture.root.view.addSubview(host)
    let editor = session.textView
    let detachedOwner = SourceTextViewHost(session: session)
    editor.removeFromSuperview()
    try #require(editor.window == nil)
    switch owner {
    case .current: break
    case .missing: session.sourceHost = nil
    case .detached: session.sourceHost = detachedOwner
    }
    host.setNeedsLayout()
    host.layoutIfNeeded()
    #expect(detachedOwner.window == nil)
    #expect(session.sourceHost === host)
    #expect(session.textView === editor)
    #expect(editor.superview === host)
    #expect(editor.window === fixture.window)
    #expect(editor.text == "# Still here")
    #expect(session.generation == 0)
  }

  @Test(arguments: [false, true])
  func animatedIdentityAndModeChangesKeepTheEditorMounted(splitNavigation: Bool) async throws {
    let session = DocumentSession(
      documentID: "animated-source", text: "# A visible source\nAn editable thought.")
    let state = ReidentifiedSourceState()
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let host = UIHostingController(
      rootView: ReidentifiedSourceFixture(
        session: session, state: state, splitNavigation: splitNavigation))
    fixture.root.addChild(host)
    host.view.frame = fixture.root.view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    fixture.root.view.addSubview(host.view)
    host.didMove(toParent: fixture.root)
    try await Task.sleep(for: .milliseconds(200))
    let editor = session.textView
    editor.selectedRange = NSRange(location: 3, length: 0)
    let selection = editor.selectedRange
    for index in 0..<4 {
      withAnimation(.easeInOut(duration: 0.1)) {
        state.identity += 1
      }
      try await Task.sleep(for: .milliseconds(250))
      host.traitOverrides.horizontalSizeClass = index.isMultiple(of: 2) ? .regular : .compact
      for mode in [NoteMode.reading, .split, .source] {
        state.mode = mode
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        #expect(session.textView === editor)
        #expect(editor.window === fixture.window)
        #expect(editor.isDescendant(of: host.view))
        #expect(editor.bounds.width > 0)
        #expect(editor.contentSize.width > 0)
        #expect(editor.selectedRange == selection)
        #expect(session.generation == 0)
        if mode == .source {
          #expect(!editor.isHidden)
          let caret = editor.caretRect(for: editor.beginningOfDocument)
          #expect(caret.height > 0)
          #expect(editor.bounds.intersects(caret))
        }
      }
    }
    Attachment.record(
      UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
      }, named: "source-after-animated-rehosting-\(splitNavigation).png", as: .png)
  }

  @Test func anOutgoingHostCannotDetachTheRetainedEditorFromItsNewHost() async throws {
    let session = DocumentSession(
      documentID: "retained", text: "# Still visible\nA retained source.")
    let other = DocumentSession(documentID: "other", text: "# A different source")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    let outgoing = UIHostingController(
      rootView: MarkdownEditorView(session: session).environment(\.isPaneVisible, true))
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
    let incomingAccessory = session.textView.inputAccessoryView

    outgoing.rootView = MarkdownEditorView(session: session)
      .environment(\.isPaneVisible, false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!session.textView.isHidden)
    #expect(session.textView.isAccessibilityElement)
    #expect(session.textView.inputAccessoryView === incomingAccessory)

    outgoing.rootView = MarkdownEditorView(session: other)
      .environment(\.isPaneVisible, false)
    outgoing.view.setNeedsLayout()
    outgoing.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    outgoing.willMove(toParent: nil)
    outgoing.view.removeFromSuperview()
    outgoing.removeFromParent()
    try await Task.sleep(for: .milliseconds(150))
    #expect(session.textView.window === window)
    #expect(session.textView.isDescendant(of: incoming.view))
    #expect(!session.textView.isHidden)
    #expect(session.textView.inputAccessoryView === incomingAccessory)
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

@MainActor
private final class SourceHostWindow {
  let window: UIWindow
  let root = UIViewController()
  private weak var previous: UIWindow?

  init() throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previous = scene.keyWindow
    window = UIWindow(windowScene: scene)
    window.rootViewController = root
    window.makeKeyAndVisible()
    root.view.layoutIfNeeded()
  }

  func close() {
    window.endEditing(true)
    window.isHidden = true
    window.rootViewController = nil
    previous?.makeKey()
  }
}

@MainActor
@Observable
private final class ReidentifiedSourceState {
  var identity = 0
  var mode = NoteMode.source
}

private struct ReidentifiedSourceFixture: View {
  let session: DocumentSession
  @Bindable var state: ReidentifiedSourceState
  let splitNavigation: Bool

  var body: some View {
    if splitNavigation {
      NavigationSplitView(preferredCompactColumn: .constant(.detail)) {
        List { Text("A visible source") }
      } detail: {
        detail
      }
    } else {
      NavigationStack { detail }
    }
  }

  private var detail: some View {
    NoteScreen(
      document: .init(
        title: "A visible source",
        files: [.init(id: "README.md", filename: "README.md")],
        selectedFileID: "README.md"),
      mode: $state.mode, saveState: .savedToGitHub
    ) {
      MarkdownEditorView(session: session)
        .id(state.identity)
        .transition(.opacity)
    } preview: {
      Text("A visible source\nAn editable thought.")
    }
  }
}
