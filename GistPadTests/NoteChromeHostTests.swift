import GistPadInterface
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct NoteChromeHostTests {
  struct Presentation: Sendable {
    let state: NoteSaveState
    let autosave: Bool
    let showsSave: Bool
    let showsOffline: Bool
  }

  @Test(arguments: [
    Presentation(state: .savedLocally, autosave: true, showsSave: false, showsOffline: false),
    Presentation(state: .offline, autosave: true, showsSave: false, showsOffline: true),
    Presentation(
      state: .cloudFailure(message: "Synthetic failure"), autosave: true,
      showsSave: true, showsOffline: false),
    Presentation(state: .savedLocally, autosave: false, showsSave: true, showsOffline: false),
  ])
  func autosaveAndOfflineHaveIndependentNativeToolbarControls(
    presentation: Presentation
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    var actions = NoteActions()
    actions.save = {}
    actions.retry = {}
    let host = UIHostingController(
      rootView: NavigationStack {
        NoteScreen(
          document: .init(
            title: "Quiet chrome", files: [.init(id: "readme", filename: "README.md")],
            selectedFileID: "readme", isAutoSaveEnabled: presentation.autosave),
          mode: .constant(.reading), saveState: presentation.state, actions: actions
        ) {
          Text("Synthetic source")
        } preview: {
          Text("Synthetic preview")
        }
      })
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(250))
    window.layoutIfNeeded()
    #expect(
      containsIdentifier("note-save", in: window) == presentation.showsSave)
    #expect(
      containsIdentifier("note-offline", in: window) == presentation.showsOffline)
  }

  private func containsIdentifier(_ identifier: String, in view: UIView) -> Bool {
    view.accessibilityIdentifier == identifier
      || (view.accessibilityElements ?? []).contains {
        ($0 as? any UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
      }
      || view.subviews.contains { containsIdentifier(identifier, in: $0) }
  }
}
