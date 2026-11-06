import Screens
import SwiftUI
import Testing
import UIKit

@testable import Editor

@Suite(.serialized)
@MainActor
struct FileSwitchingTests {
  enum OwnerState: CaseIterable {
    case current, missing, detached
  }

  @Test(arguments: [false, true])
  func supersededContainersCannotReconfigureDetachOrReclaimTheEditor(composing: Bool) throws {
    let source = "# A retained source\nAn editable thought."
    let editor = Editor(fileID: "owned-source", text: source)
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let outgoing = TextViewHost(editor: editor)
    outgoing.frame = fixture.root.view.bounds
    outgoing.configure { $0.isHidden = false }
    fixture.root.view.addSubview(outgoing)
    let textView = editor.textView
    try #require(textView.becomeFirstResponder())
    textView.selectedRange = NSRange(location: 0, length: 0)
    if composing {
      textView.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
      try #require(textView.markedTextRange != nil)
    } else {
      textView.undoManager?.beginUndoGrouping()
      textView.insertText("An edit: ")
      textView.undoManager?.endUndoGrouping()
      try #require(textView.undoManager?.canUndo == true)
    }
    let text = textView.text
    let selection = textView.selectedRange
    let generation = editor.generation
    let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
    let incoming = TextViewHost(editor: editor)
    incoming.frame = fixture.root.view.bounds
    incoming.configure {
      $0.isHidden = false
      $0.inputAccessoryView = accessory
    }
    try #require(textView.superview === outgoing)
    fixture.root.view.addSubview(incoming)
    try #require(textView.superview === incoming)

    outgoing.configure {
      $0.isHidden = true
      $0.inputAccessoryView = nil
    }
    outgoing.setNeedsLayout()
    outgoing.layoutIfNeeded()
    outgoing.dismantle()
    outgoing.removeFromSuperview()
    incoming.layoutIfNeeded()

    #expect(textView.superview === incoming)
    #expect(textView.window === fixture.window)
    #expect(textView.frame == incoming.bounds)
    #expect(!textView.isHidden)
    #expect(textView.inputAccessoryView === accessory)
    #expect(textView.isFirstResponder)
    #expect(textView.text == text)
    #expect(textView.selectedRange == selection)
    #expect(editor.generation == generation)
    #expect((textView.markedTextRange != nil) == composing)
    if !composing {
      textView.undoManager?.undo()
      #expect(textView.text == source)
    }
  }

  @Test(arguments: [false, true])
  func aReturningStaleHostCannotOrphanTheVisibleHost(dismantled: Bool) throws {
    let editor = Editor(fileID: "stale-return", text: "# Still visible")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let stale = TextViewHost(editor: editor)
    let visible = TextViewHost(editor: editor)
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
    let textView = editor.textView
    textView.selectedRange = NSRange(location: 3, length: 0)
    try #require(textView.superview === visible)

    stale.removeFromSuperview()
    fixture.root.view.addSubview(stale)
    #expect(textView.superview === visible)
    if dismantled {
      stale.dismantle()
    } else {
      stale.removeFromSuperview()
    }

    #expect(editor.host === visible)
    #expect(textView.superview === visible)
    #expect(textView.window === fixture.window)
    #expect(!textView.isHidden)
    #expect(textView.inputAccessoryView === accessory)
    #expect(textView.selectedRange == NSRange(location: 3, length: 0))
    #expect(textView.text == "# Still visible")
    #expect(editor.generation == 0)
    stale.setNeedsLayout()
    stale.layoutIfNeeded()
    #expect(textView.superview === visible)
  }

  @Test(arguments: [false, true])
  func anOwnerLeavingOrDismantlingImmediatelyReturnsTheEditorToThePreviousLiveHost(
    dismantled: Bool
  ) throws {
    let editor = Editor(fileID: "owner-left", text: "# Still attached")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let previous = TextViewHost(editor: editor)
    let owner = TextViewHost(editor: editor)
    previous.frame = fixture.root.view.bounds
    owner.frame = fixture.root.view.bounds
    fixture.root.view.addSubview(previous)
    fixture.root.view.addSubview(owner)
    let textView = editor.textView
    try #require(textView.superview === owner)
    if dismantled {
      owner.dismantle()
    } else {
      owner.removeFromSuperview()
    }
    #expect(editor.host === previous)
    #expect(textView.superview === previous)
    #expect(textView.window === fixture.window)
    #expect(textView.text == "# Still attached")
    #expect(editor.generation == 0)
  }

  @Test(arguments: OwnerState.allCases)
  func anInWindowContainerRepairsMissingDetachedAndCurrentOwnership(owner: OwnerState) throws {
    let editor = Editor(fileID: "reattached", text: "# Still here")
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let host = TextViewHost(editor: editor)
    host.frame = fixture.root.view.bounds
    fixture.root.view.addSubview(host)
    let textView = editor.textView
    let detachedOwner = TextViewHost(editor: editor)
    textView.removeFromSuperview()
    try #require(textView.window == nil)
    switch owner {
    case .current: break
    case .missing: editor.host = nil
    case .detached: editor.host = detachedOwner
    }
    host.setNeedsLayout()
    host.layoutIfNeeded()
    #expect(detachedOwner.window == nil)
    #expect(editor.host === host)
    #expect(editor.textView === textView)
    #expect(textView.superview === host)
    #expect(textView.window === fixture.window)
    #expect(textView.text == "# Still here")
    #expect(editor.generation == 0)
  }

  @Test(arguments: [false, true])
  func animatedIdentityAndModeChangesKeepTheEditorMounted(splitNavigation: Bool) async throws {
    let editor = Editor(
      fileID: "animated-source", text: "# A visible source\nAn editable thought.")
    let state = ReidentifiedSourceState()
    let fixture = try SourceHostWindow()
    defer { fixture.close() }
    let host = UIHostingController(
      rootView: ReidentifiedSourceFixture(
        editor: editor, state: state, splitNavigation: splitNavigation))
    fixture.root.addChild(host)
    host.view.frame = fixture.root.view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    fixture.root.view.addSubview(host.view)
    host.didMove(toParent: fixture.root)
    try await Task.sleep(for: .milliseconds(200))
    let textView = editor.textView
    textView.selectedRange = NSRange(location: 3, length: 0)
    let selection = textView.selectedRange
    for index in 0..<4 {
      withAnimation(.easeInOut(duration: 0.1)) {
        state.identity += 1
      }
      try await Task.sleep(for: .milliseconds(250))
      host.traitOverrides.horizontalSizeClass = index.isMultiple(of: 2) ? .regular : .compact
      for mode in [FileMode.preview, .split, .edit] {
        state.mode = mode
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        #expect(editor.textView === textView)
        #expect(textView.window === fixture.window)
        #expect(textView.isDescendant(of: host.view))
        #expect(textView.bounds.width > 0)
        #expect(textView.contentSize.width > 0)
        #expect(textView.selectedRange == selection)
        #expect(editor.generation == 0)
        if mode == .edit {
          #expect(!textView.isHidden)
          let caret = textView.caretRect(for: textView.beginningOfDocument)
          #expect(caret.height > 0)
          #expect(textView.bounds.intersects(caret))
        }
      }
    }
    Attachment.record(
      UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
        fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true)
      }, named: "source-after-animated-rehosting-\(splitNavigation).png", as: .png)
  }

  @Test func anOutgoingHostCannotDetachTheRetainedEditorFromItsNewHost() async throws {
    let editor = Editor(
      fileID: "retained", text: "# Still visible\nA retained source.")
    let other = Editor(fileID: "other", text: "# A different source")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    let outgoing = UIHostingController(
      rootView: EditorView(editor: editor).environment(\.isPaneVisible, true))
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
    try #require(editor.textView.isDescendant(of: outgoing.view))

    let incoming = UIHostingController(rootView: EditorView(editor: editor))
    root.addChild(incoming)
    incoming.view.frame = root.view.bounds
    incoming.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.view.addSubview(incoming.view)
    incoming.didMove(toParent: root)
    try await Task.sleep(for: .milliseconds(150))
    try #require(editor.textView.isDescendant(of: incoming.view))
    let incomingAccessory = editor.textView.inputAccessoryView

    outgoing.rootView = EditorView(editor: editor)
      .environment(\.isPaneVisible, false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!editor.textView.isHidden)
    #expect(editor.textView.isAccessibilityElement)
    #expect(editor.textView.inputAccessoryView === incomingAccessory)

    outgoing.rootView = EditorView(editor: other)
      .environment(\.isPaneVisible, false)
    outgoing.view.setNeedsLayout()
    outgoing.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    outgoing.willMove(toParent: nil)
    outgoing.view.removeFromSuperview()
    outgoing.removeFromParent()
    try await Task.sleep(for: .milliseconds(150))
    #expect(editor.textView.window === window)
    #expect(editor.textView.isDescendant(of: incoming.view))
    #expect(!editor.textView.isHidden)
    #expect(editor.textView.inputAccessoryView === incomingAccessory)
    #expect(editor.textView.text == "# Still visible\nA retained source.")
    #expect(editor.generation == 0)
    Attachment.record(
      UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }, named: "retained-textView-after-outgoing-host-removal.png", as: .png)
  }

  @Test func changingFilesMountsTheCorrectRetainedTextViewAndIsolatesUndo() async throws {
    let daily = Editor(fileID: "daily", text: "# Today's note\nDaily source")
    let note = Editor(fileID: "another-gist", text: "# Another gist\nIts raw source")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: EditorView(editor: daily))
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

    host.rootView = EditorView(editor: note)
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

    for editor in [daily, note, daily, note] {
      host.rootView = EditorView(editor: editor)
      try await Task.sleep(for: .milliseconds(100))
      #expect(editor.textView.window === window)
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
    host.rootView = EditorView(editor: daily)
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
  var mode = FileMode.edit
}

private struct ReidentifiedSourceFixture: View {
  let editor: Editor
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
    GistScreen(
      gist: .init(
        title: "A visible source",
        files: [.init(id: "README.md", filename: "README.md")],
        selectedFileID: "README.md"),
      mode: $state.mode, saveState: .savedToGitHub
    ) {
      EditorView(editor: editor)
        .id(state.identity)
        .transition(.opacity)
    } preview: {
      Text("A visible source\nAn editable thought.")
    }
  }
}
