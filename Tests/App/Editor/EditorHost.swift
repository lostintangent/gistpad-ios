@testable import Editor
import SwiftUI
import Testing
import UIKit

/// Shows `editor`'s text view in a key window in the app's scene. The test hides the window when
/// it ends.
func host(_ editor: MarkdownEditor, focused: Bool = true) throws -> UIWindow {
    let controller = UIViewController()
    editor.textView.frame = controller.view.bounds
    editor.textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(editor.textView)
    let window = try present(controller)
    if focused { editor.textView.becomeFirstResponder() }
    return window
}

/// Shows `editor` in its `MarkdownEditorView`, with the keyboard bar, focused in a key window in the app's
/// scene.
func hostEditor(
    _ editor: MarkdownEditor, title: String? = nil, intelligence: (@MainActor () -> Void)? = nil,
    insertImage: (@MainActor () -> Void)? = nil
) throws -> UIWindow {
    let window = try present(
        UIHostingController(
            rootView: MarkdownEditorView(
                editor: editor, title: title, insertImage: insertImage,
                intelligence: intelligence)))
    editor.textView.becomeFirstResponder()
    return window
}

private func present(_ controller: UIViewController) throws -> UIWindow {
    let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    // A phone-sized window lays out the same in either of the Duo's postures.
    window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}
