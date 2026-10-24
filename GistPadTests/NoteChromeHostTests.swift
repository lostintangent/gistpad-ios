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
    Presentation(state: .unsaved, autosave: true, showsSave: false, showsOffline: false),
    Presentation(state: .savingToGitHub, autosave: true, showsSave: false, showsOffline: false),
    Presentation(state: .savedToGitHub, autosave: true, showsSave: false, showsOffline: false),
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
    if case .cloudFailure = presentation.state {
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(image, named: "note-cloud-failure-retry.png", as: .png)
    } else {
      #expect(!containsIdentifier("note-save-issue", in: window))
      #expect(!containsIdentifier("note-save-retry", in: window))
    }
  }

  @Test(arguments: [1, 2])
  func onlyMultiFileNotesHaveATitleMenuAndItContainsOnlyFileCommands(fileCount: Int) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    var actions = NoteActions()
    actions.rename = {}
    actions.renameFile = {}
    actions.addFile = {}
    actions.selectFile = { _ in }
    let files = [
      NoteFile(id: "README.md", filename: "README.md"),
      NoteFile(id: "Ideas.md", filename: "Ideas.md"),
    ]
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        NoteScreen(
          document: .init(
            title: "A note with files", files: Array(files.prefix(fileCount)),
            selectedFileID: "README.md", isAutoSaveEnabled: true),
          mode: .constant(.reading), saveState: .savedToGitHub, actions: actions
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(250))
    let navigationBar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let item = try #require(navigationBar.topItem)
    if fileCount == 1 {
      #expect(item.titleMenuProvider == nil)
    } else {
      let menu = try #require(item.titleMenuProvider?([]))
      let titles = menuTitles(menu)
      #expect(titles.contains("README.md"))
      #expect(titles.contains("Ideas.md"))
      #expect(titles.contains("Rename Current File…"))
      #expect(titles.contains("Add File…"))
      #expect(!titles.contains("Rename Note…"))
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func menuTitles(_ menu: UIMenu) -> [String] {
    menu.children.flatMap { item in
      if let menu = item as? UIMenu { return [menu.title] + menuTitles(menu) }
      return [(item as? UIAction)?.title].compactMap { $0 }
    }
  }

  private func containsIdentifier(_ identifier: String, in view: UIView) -> Bool {
    notebookAccessibilityElement(identifier, in: view) != nil
  }
}
