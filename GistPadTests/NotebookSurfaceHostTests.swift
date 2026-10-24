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
        }, connect: {}
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

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

}
