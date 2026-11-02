#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  extension HostedEditorTests {
    @MainActor
    struct ViewportTests {
      @Test func actualViewportDoesNotCountTheKeyboardTwiceAfterTheEditorShrinks() {
        let editor = Editor(fileID: "keyboard-viewport", text: "Keep writing here")
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
        editor.view.updateViewportView(viewport)
        view.layoutIfNeeded()
        #expect(abs(view.adjustedContentInset.top - 96) < 0.001)
        #expect(abs(view.adjustedContentInset.bottom - 34) < 0.001)
        view.frame.size.height = 300
        viewport.frame.size.height = 204
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(abs(view.adjustedContentInset.top - 96) < 0.001)
        #expect(abs(view.adjustedContentInset.bottom) < 0.001)
        #expect(view.bounds.height - view.adjustedContentInset.top > 200)
        #expect(editor.text == "Keep writing here")
        #expect(editor.generation == 0)
      }

      @Test func changingChromeInsetsPreservesTheCurrentPassage() throws {
        let source = String(
          repeating: "A retained paragraph in the native source editor.\n\n", count: 80)
        let editor = Editor(fileID: "passage", text: source)
        let window = host(editor, focused: false)
        defer { window.isHidden = true }
        let view = editor.textView
        let viewport = UIView()
        try #require(view.superview).addSubview(viewport)
        viewport.frame = CGRect(x: 0, y: 96, width: 390, height: view.bounds.height - 130)
        editor.view.updateViewportView(viewport)
        editor.view.layoutDocument()
        view.layoutIfNeeded()
        try #require(view.contentSize.height > 3_000)
        view.setContentOffset(CGPoint(x: 0, y: 1_400), animated: false)
        let top = view.contentOffset.y + view.adjustedContentInset.top
        let selection = view.selectedRange
        viewport.frame = CGRect(x: 0, y: 132, width: 390, height: view.bounds.height - 166)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(abs(view.adjustedContentInset.top - 132) < 0.001)
        #expect(abs(view.contentOffset.y + view.adjustedContentInset.top - top) < 0.001)
        #expect(editor.text == source)
        #expect(editor.generation == 0)
        #expect(view.selectedRange == selection)
      }
    }
  }
#endif
