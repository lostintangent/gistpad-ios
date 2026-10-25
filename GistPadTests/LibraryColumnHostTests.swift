import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryColumnHostTests {
  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func sectionRhythmAndInnerInsetsUseOneNativeColumn(
    sidebar: Bool, size: DynamicTypeSize
  ) async throws {
    for width in [280, 350] {
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.windows.first(where: \.isKeyWindow)
      let animationsWereEnabled = UIView.areAnimationsEnabled
      UIView.setAnimationsEnabled(false)
      let window = UIWindow(windowScene: scene)
      window.frame = .init(x: 0, y: 0, width: width, height: 1600)
      let category: UIContentSizeCategory = size == .large ? .large : .accessibilityExtraLarge
      window.traitOverrides.preferredContentSizeCategory = category
      let traits = UITraitCollection(preferredContentSizeCategory: category)
      let model = LibraryModel(
        snapshot: .init(notes: [
          .init(
            id: "pinned", title: "One thought", updatedAt: InterfaceFixtures.referenceDate,
            gistID: "pinned", isPinned: true),
          .init(
            id: "listed", title: "Another thought", updatedAt: InterfaceFixtures.referenceDate,
            gistID: "listed")
        ]),
        loadState: .ready,
        today: .init(date: InterfaceFixtures.referenceDate, availability: .missing))
      window.rootViewController = UIHostingController(
        rootView: NavigationStack {
          LibraryView(
            model: model, actions: .init(refresh: {}, create: {}, today: {}),
            isSidebar: sidebar)
        }
        .environment(\.horizontalSizeClass, sidebar ? .regular : .compact)
        .environment(\.dynamicTypeSize, size)
        .environment(\.locale, Locale(identifier: "en_US"))
        .transaction { $0.disablesAnimations = true })
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
        UIView.setAnimationsEnabled(animationsWereEnabled)
      }
      let deadline = ContinuousClock.now + .seconds(5)
      while ContinuousClock.now < deadline {
        window.layoutIfNeeded()
        if descendants(window).contains(where: {
          $0.accessibilityIdentifier == "capture-frame-note-content-listed" && !$0.bounds.isEmpty
        }) { break }
        try await Task.sleep(for: .milliseconds(50))
      }

      func marker(_ identifier: String) throws -> UIView {
        try #require(descendants(window).first {
          $0.accessibilityIdentifier == "capture-frame-\(identifier)"
            && !$0.bounds.isEmpty && $0.window === window
        })
      }
      func frame(_ identifier: String) throws -> CGRect {
        let view = try marker(identifier)
        return view.convert(view.bounds, to: window)
      }
      func rowFrame(containing identifier: String) throws -> CGRect {
        var parent: UIView? = try marker(identifier)
        while let current = parent {
          if current is UICollectionViewCell || current is UITableViewCell {
            return current.convert(current.bounds, to: window)
          }
          parent = current.superview
        }
        Issue.record("Missing native List cell for \(identifier).")
        throw ColumnFailure.missingCell
      }
      let pinned = try rowFrame(containing: "note-content-pinned")
      let listed = try rowFrame(containing: "note-content-listed")
      let pinnedHeading = try frame("library-heading-pin.fill")
      let listedHeading = try frame("library-heading-doc.text")
      let metrics = UIFontMetrics(forTextStyle: .body)
      let beforeHeading = metrics.scaledValue(for: 32, compatibleWith: traits)
      let afterHeading = metrics.scaledValue(for: 12, compatibleWith: traits)
      Attachment.record(
        """
        sidebar: \(sidebar), width: \(width), size: \(size)
        pinned cell: \(pinned), listed cell: \(listed)
        pinned heading: \(pinnedHeading), listed heading: \(listedHeading)
        pinned content: \(try frame("note-content-pinned"))
        listed content: \(try frame("note-content-listed"))
        pinned title: \(try frame("note-title-pinned"))
        listed title: \(try frame("note-title-listed"))
        """, named: "column-\(sidebar)-\(width)-\(size).txt")

      #expect(abs(pinned.minX - 20) <= 1)
      #expect(abs(pinned.width - CGFloat(width - 40)) <= 1)
      #expect(abs(listed.minX - pinned.minX) <= 1)
      #expect(abs(listed.width - pinned.width) <= 1)
      #expect(abs(try frame("note-title-pinned").minX - pinned.minX - 12) <= 1)
      #expect(abs(try frame("note-title-listed").minX - listed.minX - 12) <= 1)
      if sidebar {
        let today = try rowFrame(containing: "library-today-symbol")
        #expect(abs(try frame("library-today-symbol").minX - today.minX - 12) <= 1)
        #expect(pinnedHeading.minX >= pinned.minX)
        #expect(pinnedHeading.maxX <= pinned.maxX + 1)
        #expect(listedHeading.maxX <= listed.maxX + 1)
        #expect(abs(pinnedHeading.minX - listedHeading.minX) <= 1)
        #expect(pinned.minY - pinnedHeading.maxY >= afterHeading - 1)
        #expect(listedHeading.minY - pinned.maxY >= beforeHeading - 1)
        #expect(listed.minY - listedHeading.maxY >= afterHeading - 1)
        #expect(pinnedHeading.minY - today.maxY >= beforeHeading - 1)
      } else {
        #expect(abs(pinnedHeading.minX - pinned.minX - 12) <= 1)
        #expect(abs(listedHeading.minX - listed.minX - 12) <= 1)
        #expect(abs(pinned.minY - pinnedHeading.maxY - afterHeading) <= 1)
        #expect(abs(listedHeading.minY - pinned.maxY - beforeHeading) <= 1)
        #expect(abs(listed.minY - listedHeading.maxY - afterHeading) <= 1)
      }
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}

private enum ColumnFailure: Error { case missingCell }
