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
              model: model, title: "Saturday walk", filename: "Saturday.md",
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
      let expected = PersonalAccent(savedHex: capture.accent).roles(traits: sheetTraits).text
      let counts = try nativeAccentPixels(in: image, expected: expected)
      #expect(counts.systemBlue == 0, "Intelligence must not fall back to system-blue controls.")
      if capture.state == "answer" {
        #expect(
          counts.personal > 30,
          "Verified source-reference links must use the personal accent: \(expected).")
      }
      Attachment.record(
        image,
        named:
          "intelligence-fixture-\(capture.state)-390-\(capture.accessibility ? "AX3" : "Large")-\(capture.dark ? "Dark" : "Light")\(capture.accent.map { "-\($0)" } ?? "").png",
        as: .png)
    }
  }

#endif
