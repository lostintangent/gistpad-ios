import GistPadAppearance
import GistPadInterface
import GistPadSync
import SwiftUI
import Testing
import UIKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct NotebookSurfaceHostTests {
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
  func presentedSurfacesUseTheSavedAccent(screen: String, dark: Bool) async throws {
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
        .tint(InterfaceTheme.accent)
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
    let roles = PersonalAccent(savedHex: "#FACC15").roles(traits: canvas.traitCollection)
    let expected = screen == "note-failed" ? roles.fill : roles.text
    let pixels = try nativeAccentPixels(in: image, expected: expected)
    #expect(pixels.personal > 40)
    #expect(pixels.systemBlue < 20)
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

  @Test func settingsUseSavedValuesAndExposeARejectedChangeWithoutSilentlyAcceptingIt() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    var attempted: Bool?
    let account = NotebookAccount(
      id: UUID(), login: "octavia",
      preferences: .init(metadata: ["isAutoSaveEnabled": .bool(false)]))
    window.rootViewController = UIHostingController(
      rootView: NotebookSettingsSheet(
        account: account,
        savePreference: { key, value in
          #expect(key == .isAutoSaveEnabled)
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
    let toggle = try #require(descendants(window).compactMap { $0 as? UISwitch }.first)
    #expect(!toggle.isOn)
    toggle.setOn(true, animated: false)
    toggle.sendActions(for: .valueChanged)
    try await Task.sleep(for: .milliseconds(250))
    #expect(attempted == true)
    #expect(descendants(window).compactMap { $0 as? UISwitch }.first?.isOn == false)
    let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
    #expect(alert.title == "Couldn't Confirm Setting")
    #expect(alert.message?.contains("offline") == true)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "settings-rejected-change.png", as: .png)
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

}
