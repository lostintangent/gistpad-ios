#if canImport(UIKit)
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadEditor

  // Package tests have no connected UIWindowScene, so each test hosts the editor in its own key
  // window and hides it when the test ends. Every suite that hosts a window nests here so those
  // tests run one at a time. Otherwise main-actor tests from different suites interleave at each
  // await, and one test's window takes key and first responder from another's.
  @Suite(.serialized)
  enum HostedEditorTests {}

  @MainActor
  func host(_ editor: Editor, focused: Bool = true) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let controller = UIViewController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    editor.textView.frame = controller.view.bounds
    editor.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(editor.textView)
    window.layoutIfNeeded()
    if focused { editor.textView.becomeFirstResponder() }
    return window
  }

  @MainActor
  func hostEditor(
    _ editor: Editor, title: String? = nil, intelligence: (@MainActor () -> Void)? = nil,
    insertImage: (@MainActor () -> Void)? = nil, canInsertImage: Bool = false
  ) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = UIHostingController(
      rootView: EditorView(
        editor: editor, title: title, insertImage: insertImage, canInsertImage: canInsertImage,
        intelligence: intelligence))
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    editor.textView.becomeFirstResponder()
    return window
  }
#endif
