import GistPadSync
import SwiftUI
import Testing
import UIKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct SettingsHostTests {
  @Test func settingsPersistAutosaveAndKeepFrontMatterHiddenByDefault() async throws {
    var saved: [(BooleanPreference, Bool)] = []
    let host = try await SettingsHost(
      SettingsPreferenceFixture(
        preferences: .init(metadata: ["unrelated": .string("retained")])
      ) { saved.append(($0, $1)) })
    defer { host.close() }
    // The Writing section lists Autosave, Check Spelling and Show Front Matter in order.
    let switches = host.switches
    try #require(switches.count >= 3)
    let autosave = switches[0]
    let frontMatter = switches[2]
    #expect(autosave.isOn)
    #expect(!frontMatter.isOn)
    for (toggle, preference) in [(autosave, BooleanPreference.isAutoSaveEnabled), (frontMatter, .showFrontmatter)] {
      let value = !toggle.isOn
      toggle.setOn(value, animated: false)
      toggle.sendActions(for: .valueChanged)
      try await Task.sleep(for: .milliseconds(250))
      #expect(saved.last?.0 == preference)
      #expect(saved.last?.1 == value)
      #expect(toggle.isOn == value)
    }
    #expect(saved.count == 2)
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

@MainActor
private final class SettingsHost {
  let window: UIWindow
  private let previous: UIWindow?

  init(_ root: some View) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previous = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: root)
    window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(250))
  }

  var switches: [UISwitch] {
    descendants(window).compactMap { $0 as? UISwitch }
      .sorted { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
  }

  func close() {
    window.rootViewController?.dismiss(animated: false)
    window.isHidden = true
    window.rootViewController = nil
    previous?.makeKeyAndVisible()
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
