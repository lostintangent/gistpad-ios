#if canImport(UIKit)
  import Editor
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPad

  @Suite(.serialized)
  @MainActor
  struct IntelligenceSurfaceTests {
    @Test func closingIntelligenceRestoresSourceSelectionFocusAndUndo() async throws {
      let source =
        "# Saturday walk\n\nTake teh river path.\n"
        + (1...120).map { "Stop \($0) on the river path." }.joined(separator: "\n")
      let session = Editor(fileID: "intelligence-return", text: source)
      let editor = session.textView
      let selection = (source as NSString).range(of: "Stop 60 ")
      var changes = 0
      session.onEdit = { _, _ in changes += 1 }
      let presentation = IntelligencePresentation()
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      let host = UIHostingController(
        rootView: NavigationStack {
          EditorView(editor: session).navigationTitle("Saturday walk")
        }
        .intelligenceSheet(presentation))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        editor.resignFirstResponder()
        host.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
      }
      try await waitForNativeReturnState("the retained editor to mount") {
        host.view.layoutIfNeeded()
        return editor.window === window && editor.bounds.height > 0
      }
      try #require(editor.becomeFirstResponder())
      // A writer reaches their place with the keyboard already up, so let it finish arriving.
      _ = try await settledOffset(of: editor, in: host)
      editor.selectedRange = selection
      editor.scrollRangeToVisible(selection)
      let offset = try await settledOffset(of: editor, in: host)
      try #require(offset > 0)
      presentation.present(
        editor: session, title: "Saturday walk",
        revealSource: { _ in Issue.record("Closing must not navigate to a reference.") })
      try #require(presentation.target?.wasEditing == true)
      try await waitForNativeReturnState("the sheet's prompt to mount") {
        intelligencePrompt(presentedOver: host) != nil
      }
      #expect(!editor.isFirstResponder)
      presentation.target = nil
      try await waitForNativeReturnState("dismissal to resume the original editor") {
        host.view.layoutIfNeeded()
        return host.presentedViewController == nil && editor.isFirstResponder
      }
      #expect(session.textView === editor)
      #expect(editor.selectedRange == selection)
      let returned = try await settledOffset(of: editor, in: host)
      #expect(abs(returned - offset) < 1)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      #expect(changes == 0)

      editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
      editor.insertText("\nStill editable.")
      #expect(session.text.utf8.elementsEqual((source + "\nStill editable.").utf8))
      editor.undoManager?.undo()
      #expect(session.text.utf8.elementsEqual(source.utf8))
    }

    private func waitForNativeReturnState(
      _ description: String, until ready: @MainActor () -> Bool
    ) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while ContinuousClock.now < deadline {
        if ready() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      Issue.record("Timed out waiting for \(description).")
      throw NativeReturnFailure.timedOut
    }

    /// The arriving keyboard, the collapsing title and any keyboard still leaving from an earlier
    /// test move the editor's insets for a moment, so its position is comparable once they settle.
    private func settledOffset(of editor: UITextView, in host: UIViewController) async throws
      -> CGFloat
    {
      var state: [CGFloat] = []
      var since = ContinuousClock.now
      try await waitForNativeReturnState("the keyboard to settle") {
        host.view.layoutIfNeeded()
        let current = [
          editor.contentOffset.y, editor.adjustedContentInset.top,
          editor.adjustedContentInset.bottom,
        ]
        if current != state {
          state = current
          since = .now
        }
        return editor.inputAccessoryView?.window != nil
          && ContinuousClock.now - since > .milliseconds(300)
      }
      return editor.contentOffset.y
    }

    private enum NativeReturnFailure: Error {
      case timedOut
    }

  }

  /// The sheet's prompt field, found as a view because SwiftUI only builds
  /// accessibility identifiers while an accessibility client is running.
  @MainActor
  func intelligencePrompt(presentedOver root: UIViewController) -> UITextView? {
    var presented = root.presentedViewController
    while let next = presented?.presentedViewController { presented = next }
    guard let sheet = presented, !sheet.isBeingPresented else { return nil }
    func find(in view: UIView) -> UITextView? {
      if let field = view as? UITextView { return field }
      return view.subviews.lazy.compactMap(find).first
    }
    return find(in: sheet.view)
  }
#endif
