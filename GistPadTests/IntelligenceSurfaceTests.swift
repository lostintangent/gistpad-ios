#if canImport(UIKit)
  import GistPadIntelligence
  import SwiftUI
  import Testing
  import UIKit

  @testable import GistPadEditor

  @Suite(.serialized)
  @MainActor
  struct IntelligenceSurfaceTests {
    struct Capture: Sendable {
      let state: String
      var dark = false
      var accessibility = false
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
    ])
    func nativeSheetContentWithAnExplicitFakeModel(capture: Capture) async throws {
      let source =
        "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."
      let session = DocumentSession(documentID: "surface-fixture", text: source)
      let backend = SurfaceModel()
      let model = NoteIntelligenceModel(session: session, backend: backend, isCurrent: { true })
      model.askPrompt = "What's the plan for this morning?"
      model.editPrompt = "Fix the spelling without changing the meaning."
      if capture.state == "unavailable" { backend.available = false }
      if capture.state == "readonly" { session.textView.isEditable = false }
      if capture.state == "error" { backend.unverified = true }
      if ["edit", "review", "readonly"].contains(capture.state) {
        model.action = capture.state == "edit" ? .edit : .review
      }
      await model.checkAvailability()
      if !["ask", "unavailable"].contains(capture.state) {
        model.generate()
        await model.task?.value
      }
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      window.overrideUserInterfaceStyle = capture.dark ? .dark : .light
      window.rootViewController = UIHostingController(
        rootView: Color(uiColor: .systemBackground)
          .sheet(isPresented: .constant(true)) {
            NoteIntelligenceSheet(
              model: model, title: "Saturday walk", filename: "Saturday.md",
              revealSource: { _ in Issue.record("A capture must not navigate.") }
            )
            .environment(\.dynamicTypeSize, capture.accessibility ? .accessibility3 : .large)
          })
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
      }
      try await Task.sleep(for: .milliseconds(700))
      window.layoutIfNeeded()
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(session.generation == 0)
      if capture.state == "error" {
        #expect(model.errorMessage != nil)
        #expect(model.answerParts.isEmpty)
      }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(
        image,
        named:
          "intelligence-fixture-\(capture.state)-390-\(capture.accessibility ? "AX3" : "Large")-\(capture.dark ? "Dark" : "Light").png",
        as: .png)
    }
  }

  @MainActor
  private final class SurfaceModel: NoteModelBackend {
    var available = true
    var unverified = false

    func modelInfo() async throws -> NoteModelInfo {
      guard available else {
        throw NoteIntelligenceError.unavailable(
          "Turn on Apple Intelligence in Settings to use these actions.")
      }
      return NoteModelInfo(variant: "Fixture", contextSize: 4_096)
    }

    func tokenCount(for pass: NoteModelPass) async throws -> Int { 500 }

    func replacements(for pass: NoteModelPass) async throws -> [NoteReplacementCandidate] {
      [
        NoteReplacementCandidate(
          quote: "Take teh river path.", replacement: "Take the river path.",
          reason: "Correct the spelling of “the”.")
      ]
    }

    func excerpts(for pass: NoteModelPass) async throws -> [String] { [] }

    func answer(
      for pass: NoteModelPass, onUpdate: @MainActor ([ModelAnswerPart]) -> Void
    ) async throws -> [ModelAnswerPart] {
      let parts = [
        ModelAnswerPart(kind: .prose, text: "You're planning a river walk, leaving at 9am."),
        ModelAnswerPart(
          kind: .quote, text: unverified ? "Invented source" : "Take teh river path."),
      ]
      onUpdate(parts)
      return parts
    }
  }
#endif
