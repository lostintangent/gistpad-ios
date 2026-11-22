#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import Editor

  extension HostedEditorTests {
    @MainActor
    struct ViewportTests {
      @Test func actualViewportDoesNotCountTheKeyboardTwiceAfterTheEditorShrinks() {
        let editor = Editor(text: "Keep writing here")
        let root = UIViewController()
        let view = editor.textView
        let viewport = UIView()
        root.view.addSubview(view)
        root.view.addSubview(viewport)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        viewport.frame = CGRect(x: 0, y: 96, width: 390, height: 470)
        editor.textView.updateViewportView(viewport)
        view.layoutIfNeeded()
        #expect(abs(view.contentInset.top) < 0.001)
        #expect(abs(view.adjustedContentInset.bottom - 34) < 0.001)
        view.frame.size.height = 300
        viewport.frame.size.height = 204
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(abs(view.adjustedContentInset.bottom) < 0.001)
        #expect(editor.text == "Keep writing here")
        #expect(editor.generation == 0)
      }
    }
  }
#endif
