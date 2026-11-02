#if canImport(UIKit)
  import SwiftUI
  import UIKit

  @testable import GistPadEditor

  // Package tests have no connected UIWindowScene, so each test hosts the editor in its own
  // window and hides it when the test ends.

  @MainActor
  func host(_ session: DocumentSession, focused: Bool = true) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let controller = UIViewController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    session.textView.frame = controller.view.bounds
    session.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(session.textView)
    window.layoutIfNeeded()
    if focused { session.textView.becomeFirstResponder() }
    return window
  }

  @MainActor
  func hostEditor(
    _ session: DocumentSession, intelligence: (@MainActor () -> Void)? = nil,
    insertPhoto: (@MainActor () -> Void)? = nil, canInsertPhoto: Bool = false
  ) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = UIHostingController(
      rootView: MarkdownEditorView(
        session: session, insertPhoto: insertPhoto, canInsertPhoto: canInsertPhoto,
        intelligence: intelligence))
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    session.textView.becomeFirstResponder()
    return window
  }
#endif
