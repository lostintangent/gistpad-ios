#if canImport(UIKit)
  import GistPadAppearance
  import GistPadIntelligence
  import GistPadInterface
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPad
  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceSurfaceTests {
    struct Capture: Sendable {
      let state: String
      var dark = false
      var accessibility = false
      var accent: String?
    }

    @Test(arguments: [
      Capture(state: "ask"),
      Capture(state: "answer", dark: true),
      Capture(state: "edit"),
      Capture(state: "review"),
      Capture(state: "review", accessibility: true),
      Capture(state: "readonly"),
      Capture(state: "unavailable"),
      Capture(state: "error"),
      Capture(state: "answer"),
      Capture(state: "answer", accent: "#FACC15"),
      Capture(state: "answer", dark: true, accent: "#FACC15"),
      Capture(state: "edit", dark: true, accent: "#FACC15"),
      Capture(state: "edit-long-request", accessibility: true),
    ])
    func nativeSheetContentWithAnExplicitFakeModel(capture: Capture) async throws {
      let fixture = NoteIntelligenceCaptureFixture(state: capture.state)
      let session = fixture.session
      let model = fixture.model
      await fixture.prepare()
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let previousAccent = scene.traitCollection[PersonalAccentTrait.self]
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      window.overrideUserInterfaceStyle = capture.dark ? .dark : .light
      window.rootViewController = UIHostingController(
        rootView: Color(uiColor: .systemBackground)
          .sheet(isPresented: .constant(true)) {
            NoteIntelligenceSheet(
              model: model, title: "Saturday walk",
              revealSource: { _ in Issue.record("A capture must not navigate.") }
            )
            .environment(\.dynamicTypeSize, capture.accessibility ? .accessibility3 : .large)
            .personalAccent(savedHex: capture.accent)
          }
          .personalAccent(savedHex: capture.accent)
          .background {
            NotebookSceneAccent(savedHex: capture.accent).frame(width: 0, height: 0)
          }
          .environment(\.colorScheme, capture.dark ? .dark : .light))
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        scene.traitOverrides[PersonalAccentTrait.self] = previousAccent
        previous?.makeKeyAndVisible()
      }
      try await Task.sleep(for: .milliseconds(700))
      window.layoutIfNeeded()
      #expect(session.text.utf8.elementsEqual(NoteIntelligenceCaptureFixture.source.utf8))
      #expect(session.generation == 0)
      if capture.state == "error" {
        #expect(model.errorMessage != nil)
        #expect(model.answerParts.isEmpty)
      }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let sheetTraits = try #require(
        window.rootViewController?.presentedViewController?.traitCollection)
      let canvas = try #require(window.rootViewController?.presentedViewController?.view)
      let actions = try #require(
        notebookAccessibilityElement("capture-frame-intelligence-actions", in: canvas) as? UIView)
      #expect(actions.bounds.width > 0 && actions.bounds.height > 0)
      #expect(window.bounds.contains(actions.convert(actions.bounds, to: window)))
      let expected = try #require(RGBColor(
        uiColor: UIColor.label.resolvedColor(with: sheetTraits)))
      let counts = try nativeAccentPixels(in: image, expected: expected)
      #expect(counts.systemBlue == 0, "Intelligence commands stay neutral, separate from text entry.")
      if capture.state == "answer" {
        #expect(
          counts.personal > 30,
          "Verified source-reference controls retain readable native primary ink.")
      }
      let accent = PersonalAccent(savedHex: capture.accent).roles(traits: sheetTraits).text
      #expect(try nativeAccentPixels(in: image, expected: accent).personal < 20)
      Attachment.record(
        image,
        named:
          "intelligence-fixture-\(capture.state)-390-\(capture.accessibility ? "AX3" : "Large")-\(capture.dark ? "Dark" : "Light")\(capture.accent.map { "-\($0)" } ?? "").png",
        as: .png)
    }

    @Test(arguments: ["pending-success", "pending-cancel", "pending-error"], [false, true])
    func aGenuineZeroAnswerWaitKeepsProgressAndCancelVisible(
      state: String, accessibility: Bool
    ) async throws {
      let fixture = NoteIntelligenceCaptureFixture(state: state)
      await fixture.prepare()
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.traitOverrides.preferredContentSizeCategory =
        accessibility ? .accessibilityExtraLarge : .large
      window.rootViewController = UIHostingController(
        rootView: Color(uiColor: .systemBackground)
          .sheet(isPresented: .constant(true)) {
            NoteIntelligenceSheet(
              model: fixture.model, title: "Saturday walk",
              revealSource: { _ in Issue.record("Pending generation must not navigate.") }
            )
            .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
          })
      window.makeKeyAndVisible()
      defer {
        fixture.model.cancel()
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
      }
      try await waitForNativeReturnState("a genuinely empty answer generation to begin") {
        fixture.answerStartedAt != nil
          && window.rootViewController?.presentedViewController?.isBeingPresented == false
      }
      let started = try #require(fixture.answerStartedAt)
      while started.duration(to: .now) < .seconds(5.1) {
        #expect(fixture.model.isRunning)
        #expect(fixture.model.answerParts.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
      }
      let canvas = try #require(window.rootViewController?.presentedViewController?.view)
      canvas.layoutIfNeeded()
      for id in ["intelligence-submitted-request", "intelligence-progress", "intelligence-cancel"] {
        let probe = try #require(
          notebookAccessibilityElement("capture-frame-\(id)", in: canvas) as? UIView)
        let frame = probe.convert(probe.bounds, to: window)
        if accessibility, id == "intelligence-submitted-request" {
          #expect(window.bounds.intersects(frame))
        } else {
          #expect(window.bounds.insetBy(dx: 0, dy: 1).contains(frame))
        }
        #expect(frame.width > 0 && frame.height > 0)
        if id == "intelligence-cancel" { #expect(frame.height >= 44) }
      }
      #expect(fixture.model.answerParts.isEmpty)
      #expect(fixture.model.isRunning)
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(
        image, named: "intelligence-\(state)-zero-answer-\(accessibility ? "AX3" : "Large").png",
        as: .png)
      if state == "pending-cancel" {
        fixture.model.cancel()
      }
      try await waitForNativeReturnState("the pending generation to reach its terminal state") {
        !fixture.model.isRunning
      }
      await fixture.model.task?.value
      #expect(!fixture.model.isRunning)
      #expect(fixture.model.askPrompt.count > 200)
      #expect(fixture.session.generation == 0)
      #expect(fixture.session.text.utf8.elementsEqual(NoteIntelligenceCaptureFixture.source.utf8))
      if state == "pending-success" {
        #expect(!fixture.model.answerParts.isEmpty)
        #expect(fixture.model.errorMessage == nil)
      } else {
        #expect(fixture.model.answerParts.isEmpty)
        if state == "pending-error" { #expect(fixture.model.errorMessage != nil) }
      }
    }

    @Test func dismissingAResultRestoresSourceSelectionFocusAndUndo() async throws {
      let fixture = NoteIntelligenceCaptureFixture(state: "edit")
      await fixture.prepare()
      try #require(fixture.model.hasResults)
      try #require(fixture.model.proposal?.canApply == true)
      let session = fixture.session
      let source = session.text
      let editor = session.textView
      let generation = session.generation
      let selection = (source as NSString).range(of: "river")
      try #require(selection.location != NSNotFound)
      var changes = 0
      session.onSourceChange = { _, _ in changes += 1 }
      let presentation = NotebookIntelligencePresentation()
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      let host = UIHostingController(
        rootView: IntelligenceReturnHost(fixture: fixture, presentation: presentation))
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
      editor.selectedRange = selection
      presentation.present(
        session: session, title: "Saturday walk",
        isCurrent: { true },
        revealSource: { _ in Issue.record("Closing must not navigate to a reference.") })
      try #require(presentation.target?.wasEditing == true)
      try await waitForNativeReturnState("the result to mount") {
        guard let sheet = host.presentedViewController, !sheet.isBeingPresented else {
          return false
        }
        sheet.view.layoutIfNeeded()
        let result = notebookAccessibilityElement(
          "capture-frame-intelligence-results", in: sheet.view) as? UIView
        return result?.window === window && (result?.bounds.height ?? 0) > 0
      }
      let sheet = try #require(host.presentedViewController)
      try #require(sheet.presentingViewController != nil)
      #expect(!editor.isFirstResponder)
      presentation.target = nil
      try await waitForNativeReturnState("dismissal to resume the original editor") {
        host.view.layoutIfNeeded()
        return host.presentedViewController == nil && presentation.target == nil
          && editor.isFirstResponder
      }
      #expect(session.textView === editor)
      #expect(editor.window === window)
      #expect(editor.isEditable && session.canFormat)
      #expect(editor.selectedRange == selection)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == generation)
      #expect(changes == 0, "Closing a result must not apply or publish a source change.")
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(image, named: "intelligence-close-return.png", as: .png)

      editor.selectedRange = NSRange(location: source.utf16.count, length: 0)
      editor.insertText("\nStill editable.")
      #expect(session.text.utf8.elementsEqual((source + "\nStill editable.").utf8))
      #expect(editor.isFirstResponder)
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

    private enum NativeReturnFailure: Error {
      case timedOut
    }

  }

  @MainActor
  private struct IntelligenceReturnHost: View {
    let fixture: NoteIntelligenceCaptureFixture
    @Bindable var presentation: NotebookIntelligencePresentation

    var body: some View {
      NavigationStack {
        MarkdownEditorView(session: fixture.session)
          .navigationTitle("Saturday walk")
      }
      .sheet(item: $presentation.target, onDismiss: presentation.dismissed) { target in
        NoteIntelligenceSheet(
          model: fixture.model, title: target.title,
          revealSource: {
            target.reference = .init(range: $0, generation: target.session.generation)
          })
      }
    }
  }

#endif
