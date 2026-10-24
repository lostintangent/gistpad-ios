import GistPadAppearance
import GistPadEditor
import GistPadInterface
import GistPadPreview
import GistPadSync
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct NotebookSurfaceHostTests {
  @Test(arguments: [NoteMode.source, .reading, .split])
  func retainedNativePanesFollowTheirVisibility(mode: NoteMode) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let session = DocumentSession(documentID: "pane-visibility", text: "# Retained words")
    window.rootViewController = UIHostingController(rootView: NavigationStack {
      NoteScreen(
        document: .init(
          title: "A note", files: [.init(id: "README.md", filename: "README.md")],
          selectedFileID: "README.md"),
        mode: .constant(mode), saveState: .savedLocally, allowsSplit: true
      ) {
        MarkdownEditorView(session: session)
          .safeAreaInset(edge: .bottom) {
            PhotoAttachmentShelf(attachments: [.init(id: UUID(), phase: .queued)], details: {})
          }
      } preview: {
        MarkdownPreviewView(
          document: session.text, documentID: session.documentID,
          generation: session.generation, onEvent: { _ in })
          .safeAreaInset(edge: .bottom) {
            PhotoAttachmentShelf(attachments: [.init(id: UUID(), phase: .queued)], details: {})
          }
      }
    })
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let preview = try #require(descendants(window).compactMap { $0 as? WKWebView }.first)
    let editor = session.textView
    Attachment.record(
      """
      \(mode): source hidden \(editor.isHidden), AX \(editor.isAccessibilityElement), \
      children hidden \(editor.accessibilityElementsHidden), window \(editor.window != nil)
      preview hidden \(preview.isHidden), AX \(preview.isAccessibilityElement), \
      children hidden \(preview.accessibilityElementsHidden), window \(preview.window != nil)
      """, named: "native-pane-visibility-\(mode).txt")
    #expect(editor.window === window)
    #expect(preview.window === window)
    #expect(editor.isHidden == (mode == .reading))
    #expect(editor.isAccessibilityElement == (mode != .reading))
    #expect(editor.accessibilityElementsHidden == (mode == .reading))
    #expect(preview.isHidden == (mode == .source))
    #expect(preview.accessibilityElementsHidden == (mode == .source))
    let sourcePoint = editor.convert(
      CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: window)
    let previewPoint = preview.convert(
      CGPoint(x: preview.bounds.midX, y: preview.bounds.midY), to: window)
    #expect(window.hitTest(sourcePoint, with: nil)?.isDescendant(of: editor) == (mode != .reading))
    #expect(window.hitTest(previewPoint, with: nil)?.isDescendant(of: preview) == (mode != .source))
    let summaries = descendants(window).filter {
      $0.accessibilityIdentifier == "pending-photos-summary"
    }
    #expect(summaries.count == 2)
    #expect(summaries.filter { !$0.isHidden && $0.isAccessibilityElement }.count == (mode == .split ? 2 : 1))
    for summary in summaries {
      #expect(summary.accessibilityElementsHidden == summary.isHidden)
      #expect(summary.isAccessibilityElement == !summary.isHidden)
    }
  }

  @Test func captureWorkspaceKeepsTheRetainedSourceNativelyHidden() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView:
      NotebookSurfaceCaptureWorkspace(screen: "note-chrome")
        .environment(\.dynamicTypeSize, .accessibility3))
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(800))
    window.layoutIfNeeded()
    func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let editor = try #require(descendants(window).compactMap { $0 as? UITextView }.first)
    let preview = try #require(descendants(window).compactMap { $0 as? WKWebView }.first)
    Attachment.record(
      """
      source hidden \(editor.isHidden), AX \(editor.isAccessibilityElement), \
      children hidden \(editor.accessibilityElementsHidden)
      preview hidden \(preview.isHidden), children hidden \(preview.accessibilityElementsHidden)
      """, named: "capture-root-native-pane-visibility.txt")
    #expect(editor.isHidden)
    #expect(!editor.isAccessibilityElement)
    #expect(editor.accessibilityElementsHidden)
    #expect(!preview.isHidden)
    #expect(!preview.accessibilityElementsHidden)
    let point = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: window)
    #expect(window.hitTest(point, with: nil)?.isDescendant(of: editor) == false)
  }

  struct Capture: Sendable {
    let screen: String
    let dark: Bool
    let accessibility: Bool
  }

  @Test(arguments: [
    Capture(screen: "settings", dark: false, accessibility: false),
    Capture(screen: "settings", dark: true, accessibility: false),
    Capture(screen: "settings", dark: false, accessibility: true),
    Capture(screen: "settings-signed-out", dark: false, accessibility: false),
    Capture(screen: "tags", dark: false, accessibility: false),
    Capture(screen: "tags", dark: true, accessibility: false),
    Capture(screen: "tags", dark: false, accessibility: true),
    Capture(screen: "account", dark: false, accessibility: false),
    Capture(screen: "account", dark: true, accessibility: false),
    Capture(screen: "account", dark: false, accessibility: true),
    Capture(screen: "note-loading", dark: false, accessibility: false),
    Capture(screen: "note-failed", dark: false, accessibility: false),
  ])
  func nativeSurfaceCapturesForDesignReview(capture: Capture) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 466, height: 1012)
    window.overrideUserInterfaceStyle = capture.dark ? .dark : .light
    window.traitOverrides.preferredContentSizeCategory =
      capture.accessibility ? .accessibilityExtraLarge : .large
    let host = UIHostingController(
      rootView: NotebookSurfaceCaptureWorkspace(screen: capture.screen)
        .environment(\.dynamicTypeSize, capture.accessibility ? .accessibility3 : .large))
    host.traitOverrides.preferredContentSizeCategory = capture.accessibility ? .accessibilityExtraLarge : .large
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(800))
    window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let size = capture.accessibility ? "RequestedAX3" : "Large"
    Attachment.record(
      image,
      named: "\(capture.screen)-466-\(size)-\(capture.dark ? "Dark" : "Light").png",
      as: .png)
  }

  @Test(arguments: ["settings", "tags", "note-failed"], [false, true])
  func presentedSurfacesKeepChromeNeutral(screen: String, dark: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let hadOverride = scene.traitOverrides.contains(PersonalAccentTrait.self)
    let original = scene.traitCollection[PersonalAccentTrait.self]
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.rootViewController = UIHostingController(
      rootView: NotebookSurfaceCaptureWorkspace(screen: screen, accent: "#FACC15")
        .environment(\.dynamicTypeSize, .large)
        .background {
          NotebookSceneAccent(savedHex: "#FACC15").frame(width: 0, height: 0)
        })
    window.makeKeyAndVisible()
    defer {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      if hadOverride {
        scene.traitOverrides[PersonalAccentTrait.self] = original
      } else {
        scene.traitOverrides.remove(PersonalAccentTrait.self)
      }
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(800))
    window.layoutIfNeeded()
    let canvas = try #require(
      screen == "note-failed"
        ? window.rootViewController?.view
        : window.rootViewController?.presentedViewController?.view)
    let bounds = CGRect(
      origin: .zero,
      size: CGSize(
        width: canvas.bounds.width,
        height: screen == "settings" ? min(440, canvas.bounds.height) : canvas.bounds.height))
    let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
      canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
    }
    let expected = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: canvas.traitCollection)))
    let pixels = try nativeAccentPixels(in: image, expected: expected)
    #expect(pixels.personal > 40)
    #expect(pixels.systemBlue < 20)
    let accent = PersonalAccent(savedHex: "#FACC15").roles(traits: canvas.traitCollection).text
    #expect(try nativeAccentPixels(in: image, expected: accent).personal < 20)
    if screen == "settings" {
      let toggle = try #require(descendants(canvas).compactMap { $0 as? UISwitch }.first)
      if let onTint = toggle.onTintColor {
        #expect(onTint.resolvedColor(with: toggle.traitCollection)
          .isEqual(UIColor.systemGreen.resolvedColor(with: toggle.traitCollection)))
      }
    }
    Attachment.record(
      image, named: "\(screen)-saved-yellow-\(dark ? "Dark" : "Light").png", as: .png)
  }

  @Test func sceneAccentUpdatesPresentedControllersAndResetsAfterSignOut() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let hadOverride = scene.traitOverrides.contains(PersonalAccentTrait.self)
    let original = scene.traitCollection[PersonalAccentTrait.self]
    let window = UIWindow(windowScene: scene)
    let root = UIViewController()
    window.rootViewController = root
    window.makeKeyAndVisible()
    defer {
      root.dismiss(animated: false)
      window.isHidden = true
      if hadOverride {
        scene.traitOverrides[PersonalAccentTrait.self] = original
      } else {
        scene.traitOverrides.remove(PersonalAccentTrait.self)
      }
      previous?.makeKeyAndVisible()
    }
    let bridge = NotebookSceneAccentView(accent: PersonalAccent(savedHex: "#FACC15"))
    root.view.addSubview(bridge)
    let presented = UIViewController()
    root.present(presented, animated: false)
    try await Task.sleep(for: .milliseconds(250))
    window.layoutIfNeeded()
    #expect(presented.traitCollection[PersonalAccentTrait.self].color.hex == "#FACC15")
    bridge.updateAccent(PersonalAccent(savedHex: "#DB9E47"))
    try await Task.sleep(for: .milliseconds(100))
    window.layoutIfNeeded()
    #expect(presented.traitCollection[PersonalAccentTrait.self].color.hex == "#DB9E47")
    bridge.updateAccent(PersonalAccent())
    try await Task.sleep(for: .milliseconds(100))
    window.layoutIfNeeded()
    #expect(presented.traitCollection[PersonalAccentTrait.self].color == .sky)
  }

  @Test(arguments: [BooleanPreference.isAutoSaveEnabled, .showFrontmatter])
  func settingsUseSavedValuesAndExposeARejectedChangeWithoutSilentlyAcceptingIt(
    preference: BooleanPreference
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    var attempted: Bool?
    let account = NotebookAccount(
      id: UUID(), login: "octavia",
      preferences: .init(metadata: [preference.rawValue: .bool(false)]))
    window.rootViewController = UIHostingController(
      rootView: NotebookSettingsSheet(
        account: account,
        savePreference: { key, value in
          #expect(key == preference)
          attempted = value
          throw URLError(.notConnectedToInternet)
        }, connect: {}, signOut: {}
      ) {
        Text("Accent Color")
      })
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(250))
    let identifier = preference == .showFrontmatter ? "settings-front-matter" : "settings-autosave"
    let toggle = try #require(preferenceSwitch(identifier, in: window))
    #expect(!toggle.isOn)
    toggle.setOn(true, animated: false)
    toggle.sendActions(for: .valueChanged)
    try await Task.sleep(for: .milliseconds(250))
    #expect(attempted == true)
    #expect(toggle.isOn == false)
    let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
    #expect(alert.title == "Couldn't Confirm Setting")
    #expect(alert.message?.contains("offline") == true)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "settings-rejected-change.png", as: .png)
  }

  @Test(arguments: [nil, false, true] as [Bool?])
  func frontMatterDefaultsToHiddenAndSavesTheSharedPreference(stored: Bool?) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    var saved: [(BooleanPreference, Bool)] = []
    var metadata: [String: MetadataValue] = ["unrelated": .string("retained")]
    metadata["showFrontmatter"] = stored.map(MetadataValue.bool)
    window.rootViewController = UIHostingController(
      rootView: SettingsPreferenceFixture(preferences: .init(metadata: metadata)) { key, value in
        saved.append((key, value))
      })
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(250))
    let toggle = try #require(preferenceSwitch("settings-front-matter", in: window))
    let initial = stored ?? false
    #expect(toggle.isOn == initial)
    for value in [!initial, initial] {
      toggle.setOn(value, animated: false)
      toggle.sendActions(for: .valueChanged)
      try await Task.sleep(for: .milliseconds(250))
      #expect(saved.last?.0 == .showFrontmatter)
      #expect(saved.last?.1 == value)
      #expect(toggle.isOn == value)
    }
    #expect(saved.count == 2)
  }

  @Test(arguments: [false, true])
  func signOutUsesAnAlertWithBothActionsAndDoesNotSubmitBeforeConfirmation(accessibility: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.traitOverrides.preferredContentSizeCategory =
      accessibility ? .accessibilityExtraLarge : .large
    var signOutAttempts = 0
    window.rootViewController = UIHostingController(
      rootView: NotebookSettingsSheet(
        account: .init(id: UUID(), login: "octavia", preferences: .init(metadata: [:])),
        savePreference: { _, _ in }, connect: {}, signOut: { signOutAttempts += 1 }
      ) {
        Text("Accent Color")
      }
      .captureSignOutConfirmation(true)
      .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large))
    window.makeKeyAndVisible()
    defer {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(500))
    let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
    #expect(alert.preferredStyle == .alert)
    #expect(alert.title == "Sign Out?")
    #expect(alert.message == "Drafts for @octavia stay on this iPhone. Nothing is published.")
    #expect(alert.actions.contains { $0.title == "Cancel" && $0.style == .cancel })
    #expect(alert.actions.contains { $0.title == "Sign Out" && $0.style == .destructive })
    #expect(signOutAttempts == 0)
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func preferenceSwitch(_ identifier: String, in window: UIWindow) -> UISwitch? {
    guard let row = descendants(window).first(where: {
      $0.accessibilityIdentifier == "capture-frame-\(identifier)"
    }) else { return nil }
    let frame = row.convert(row.bounds, to: window)
    return descendants(window).compactMap { $0 as? UISwitch }.first {
      frame.intersects($0.convert($0.bounds, to: window))
    }
  }

  private struct SettingsPreferenceFixture: View {
    @State var preferences: Preferences
    let saved: @MainActor (BooleanPreference, Bool) -> Void

    var body: some View {
      NotebookSettingsSheet(
        account: .init(id: UUID(), login: "octavia", preferences: preferences),
        savePreference: { key, value in
          preferences = try preferences.applying(.setBoolean(key, value))
          #expect(preferences.metadata["unrelated"] == .string("retained"))
          saved(key, value)
        }, connect: {}, signOut: {}
      ) {
        Text("Accent Color")
      }
    }
  }
}
