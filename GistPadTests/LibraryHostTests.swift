import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryHostTests {
  @Test(arguments: LibraryCollection.allCases)
  func titleMenuContainsEveryCollectionAndChecksOnlyTheCurrentCollection(
    collection: LibraryCollection
  ) async throws {
    let currentTitle = switch collection {
    case .gists: "All Notes"
    case .dailyNotes: "Daily Notes"
    case .starred: "Starred"
    case .archive: "Archive"
    }
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
    let window = UIWindow(windowScene: scene)
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.collection = collection
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let item = try #require(bar.topItem)
    #expect(item.title == (collection == .gists ? "Library" : currentTitle))
    let menu = try #require(item.titleMenuProvider?([]))
    let choices = menuActions(menu)
    let titles = Set(choices.map(\.title))
    #expect(titles.isSuperset(of: ["All Notes", "Daily Notes", "Starred", "Archive"]))
    let selected = choices.filter { $0.state == .on }
    #expect(selected.map(\.title) == [currentTitle])
  }

  @Test(arguments: [323, 324])
  func featuredCardsNeedTwoReadableColumns(usableWidth: Int) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
    let window = UIWindow(windowScene: scene)
    var frames: [Int: CGRect] = [:]
    window.rootViewController = UIHostingController(
      rootView: HStack(spacing: 0) {
        LibraryView.FeaturedGrid {
          ForEach(0..<2) { index in
            Text("Card")
              .padding(16)
              .frame(maxWidth: .infinity)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frames[index] = $0
              }
          }
        }
        .frame(width: CGFloat(usableWidth))
        Spacer(minLength: 0)
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let first = try #require(frames[0])
    let second = try #require(frames[1])
    if usableWidth == 324 {
      #expect(abs(first.minY - second.minY) < 1)
      #expect(first.width >= 156)
      #expect(second.width >= 156)
      #expect(abs(second.minX - first.maxX - 12) < 1)
    } else {
      #expect(second.minY >= first.maxY)
      #expect(first.width > 300)
    }
  }

  @Test(arguments: [280, 900], [false, true])
  func mountedSidebarAndWideLayoutsStayNative(width: Int, dark: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: width, height: 800)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let content: AnyView
    let model = LibraryModel(
      snapshot: InterfaceFixtures.library, loadState: .ready,
      today: .init(date: InterfaceFixtures.referenceDate, availability: .missing))
    if width == 280 {
      content = AnyView(
        NavigationStack {
          LibraryView(
            model: model,
            actions: .init(refresh: {}, create: {}, today: {}))
        })
    } else {
      content = AnyView(
        NavigationSplitView {
          LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
        } detail: {
          NavigationStack {
            TodayLanding(summary: model.today) {}
          }
        })
    }
    let host = UIHostingController(
      rootView: content
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.colorScheme, dark ? .dark : .light))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .seconds(1))
    window.layoutIfNeeded()
    #expect(host.view.bounds.width == CGFloat(width))
    #expect(descendants(window).contains { $0 is UINavigationBar })
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image, named: "mounted-library-\(width)-\(dark ? "Dark" : "Light")-Large.png", as: .png)
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func menuActions(_ menu: UIMenu) -> [UIAction] {
    menu.children.flatMap { child in
      if let menu = child as? UIMenu { return menuActions(menu) }
      return (child as? UIAction).map { [$0] } ?? []
    }
  }

}
