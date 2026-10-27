import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryFilterRetentionHostTests {
  @Test(arguments: LibraryFilterChange.allCases)
  func filteringClearsOnlyVisibleSelection(change: LibraryFilterChange) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 951, height: 669)
    window.traitOverrides.horizontalSizeClass = .regular
    window.traitOverrides.preferredContentSizeCategory = .large
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.selectedNoteID = "shape"
    var departures = 0
    window.rootViewController = UIHostingController(
      rootView: LibraryRetentionProbe(model: model) { departures += 1 })
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
      UIView.setAnimationsEnabled(animationsWereEnabled)
    }

    try await waitForSelectedCellCount(1, in: window)
    switch change {
    case .tags:
      model.selectedTagIDs = ["personal"]
    case .search:
      model.query = "No matching synthetic words"
      model.searchState = .results(
        notes: [],
        coverage: .init(
          totalDocuments: model.snapshot.notes.count, documentsWithCachedContent: 0))
    }
    #expect(!model.matchingNotes.contains { $0.id == "shape" })
    try await waitForSelectedCellCount(0, in: window)
    #expect(model.selectedNoteID == "shape")
    #expect(departures == 0)

    model.clearFilters()
    model.searchState = .inactive
    try await waitForSelectedCellCount(1, in: window)
    #expect(model.selectedNoteID == "shape")
    #expect(departures == 0)

    model.selectedNoteID = nil
    try await waitForSelectedCellCount(0, in: window)
    #expect(departures == 1)
  }

  @Test func compactRowsRetainIdentityWithoutSidebarSelection() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.selectedNoteID = "shape"
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}),
          isSidebar: false)
      }
      .environment(\.horizontalSizeClass, .compact))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await waitForSelectedCellCount(0, in: window)
    #expect(model.selectedNoteID == "shape")
    #expect(model.visibleSelectedNoteID == "shape")
  }

  private func waitForSelectedCellCount(_ count: Int, in window: UIWindow) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    var stableSince = ContinuousClock.now
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      let selected = descendants(window).compactMap { $0 as? UICollectionView }
        .reduce(0) { $0 + ($1.indexPathsForSelectedItems?.count ?? 0) }
      if selected != count {
        stableSince = ContinuousClock.now
      } else if ContinuousClock.now >= stableSince + .milliseconds(150) {
        return
      }
      try await Task.sleep(for: .milliseconds(30))
    }
    Issue.record("The native Library did not settle with \(count) selected cells.")
    throw LibrarySelectionFailure.timedOut
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}

enum LibraryFilterChange: CaseIterable, Sendable {
  case tags, search
}

private struct LibraryRetentionProbe: View {
  let model: LibraryModel
  let didDepart: @MainActor () -> Void

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      LibraryView(
        model: model, actions: .init(refresh: {}, create: {}, today: {}),
        isSidebar: true)
    } detail: {
      Text("Retained document")
    }
    .librarySearch(model: model)
    .environment(\.horizontalSizeClass, .regular)
    .environment(\.dynamicTypeSize, .large)
    .onChange(of: model.selectedNoteID) { old, new in
      if old == "shape", new != old { didDepart() }
    }
  }
}

private enum LibrarySelectionFailure: Error { case timedOut }
