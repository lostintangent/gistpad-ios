#if canImport(UIKit)
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct SourceViewportTests {
    @Test func measuredInsetsRevealTheFirstLineWithoutChangingTheDocument() {
      let source = "# A visible first line"
      let session = DocumentSession(documentID: "viewport", text: source)
      let view = session.textView
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
      view.layoutIfNeeded()
      session.updateViewportInsets(UIEdgeInsets(top: 96, left: 0, bottom: 34, right: 0))
      view.layoutIfNeeded()
      #expect(abs(view.adjustedContentInset.top - 96) < 0.001)
      #expect(abs(view.adjustedContentInset.bottom - 34) < 0.001)
      #expect(abs(view.contentOffset.y + view.adjustedContentInset.top) < 0.001)
      #expect(view.textContainerInset.top == 24)
      #expect(session.text == source)
      #expect(session.generation == 0)
      #expect(session.selection == NSRange(location: 0, length: 0))
      #expect(view.undoManager?.canUndo != true)
    }

    @Test func changingChromeInsetsPreservesTheCurrentPassage() throws {
      let source = String(
        repeating: "A retained paragraph in the native source editor.\n\n", count: 80)
      let session = DocumentSession(documentID: "passage", text: source)
      let view = session.textView
      view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
      view.layoutIfNeeded()
      if let manager = view.textLayoutManager, let range = manager.textContentManager?.documentRange
      {
        manager.ensureLayout(for: range)
      }
      view.layoutIfNeeded()
      try #require(view.contentSize.height > 2_000)
      session.updateViewportInsets(UIEdgeInsets(top: 96, left: 0, bottom: 34, right: 0))
      view.setContentOffset(CGPoint(x: 0, y: 1_400), animated: false)
      let top = view.contentOffset.y + view.adjustedContentInset.top
      session.updateViewportInsets(UIEdgeInsets(top: 132, left: 0, bottom: 34, right: 0))
      #expect(abs(view.contentOffset.y + view.adjustedContentInset.top - top) < 0.001)
      #expect(session.text == source)
      #expect(session.generation == 0)
      #expect(session.selection == NSRange(location: 0, length: 0))
    }

    @Test func measuredInsetsDoNotDoubleTheUIKitSafeAreaContribution() throws {
      let session = DocumentSession(documentID: "native-insets", text: "A native source page")
      let view = session.textView
      view.contentInsetAdjustmentBehavior = .always
      let controller = UIViewController()
      controller.view = view
      controller.additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 0, bottom: 16, right: 0)
      // Package logic tests have no connected UIWindowScene.
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
      window.rootViewController = controller
      window.makeKeyAndVisible()
      defer { window.isHidden = true }
      window.layoutIfNeeded()
      let automatic = view.adjustedContentInset
      try #require(automatic.top >= 44)
      let target = UIEdgeInsets(
        top: automatic.top + 20, left: 0, bottom: automatic.bottom + 12, right: 0)
      session.updateViewportInsets(target)
      view.layoutIfNeeded()
      #expect(abs(view.contentInset.top - 20) < 0.001)
      #expect(abs(view.contentInset.bottom - 12) < 0.001)
      #expect(abs(view.adjustedContentInset.top - target.top) < 0.001)
      #expect(abs(view.adjustedContentInset.bottom - target.bottom) < 0.001)
      #expect(session.text == "A native source page")
      #expect(session.generation == 0)
    }
  }
#endif
