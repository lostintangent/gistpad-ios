import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct TodayFeatureHostTests {
  @Test(arguments: [false, true], [false, true])
  func taskStatusInkIsIndependentOfAccentAndMeetsContrast(dark: Bool, increased: Bool) throws {
    func traits(accent: String) -> UITraitCollection {
      UITraitCollection {
        $0.userInterfaceStyle = dark ? .dark : .light
        $0.accessibilityContrast = increased ? .high : .normal
        $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: accent)
      }
    }
    let first = traits(accent: "#FACC15")
    let second = traits(accent: "#A855F7")
    for color in [InterfaceTheme.taskCompletion, InterfaceTheme.overdue] {
      let resolved = try #require(RGBColor(uiColor: UIColor(color).resolvedColor(with: first)))
      let alternate = try #require(RGBColor(uiColor: UIColor(color).resolvedColor(with: second)))
      #expect(resolved == alternate)
      for surface: UIColor in [
        .systemBackground, .secondarySystemBackground, .tertiarySystemBackground,
        .systemGroupedBackground, .secondarySystemGroupedBackground, .tertiarySystemGroupedBackground
      ] {
        let background = try #require(RGBColor(uiColor: surface.resolvedColor(with: first)))
        #expect(resolved.contrast(with: background) >= (increased ? 7 : 4.5))
      }
    }
  }

  @Test(arguments: [CGFloat(248), 355, 600],
    [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func usefulTodayContentFitsItsActualMeasureAndKeepsHonestTaskState(
    cardWidth: CGFloat, category: UIContentSizeCategory
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame.size.width = max(466, cardWidth + 32)
    window.traitOverrides.preferredContentSizeCategory = category
    let summaries: [LibraryTodaySummary] = [
      summary(progress: nil),
      summary(progress: .init(completed: 0, total: 0)),
      summary(progress: .init(completed: 1, total: 3)),
      summary(progress: .init(completed: 1, total: 1)),
      .init(date: InterfaceFixtures.referenceDate, availability: .missing),
    ]
    var measured: CGSize?
    func content(_ index: Int) -> some View {
      VStack {
        TodayFeature(summary: summaries[index])
          .frame(width: cardWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
          .id(index)
        Spacer(minLength: 0)
      }
      .personalAccent(savedHex: "#FACC15")
      .padding(.top, 16)
    }
    let host = UIHostingController(rootView: content(0))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    for index in summaries.indices {
      measured = nil
      host.rootView = content(index)
      try await Task.sleep(for: .milliseconds(350))
      window.layoutIfNeeded()
      let size = try #require(measured)
      #expect(abs(size.width - cardWidth) <= 0.5)
      #expect(size.height >= 44)
      #expect(size.height < window.bounds.height)
      if cardWidth >= 355, category == .large {
        #expect(size.height < 190, "Content belongs beside the date, not in another full-width row.")
        let date = try #require(frame("today-date-tile", in: window))
        let title = try #require(frame("today-title", in: window))
        #expect(title.minX >= date.maxX + 15)
        #expect(abs(title.minY - date.minY) <= 1)
        if summaries[index].availability == .existing {
          let excerpt = try #require(frame("today-excerpt", in: window))
          #expect(excerpt.minX >= date.maxX + 15)
          #expect(excerpt.minY >= title.maxY)
        }
        if let progress = summaries[index].progress, progress.total > 0 {
          let tasks = try #require(frame("today-tasks", in: window))
          #expect(tasks.minX >= title.maxX + 7)
          #expect(!tasks.intersects(title))
        } else {
          #expect(frame("today-tasks", in: window) == nil)
        }
      } else {
        #expect(frame("today-compact-heading", in: window) != nil)
      }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(
        image, named: "today-\(Int(cardWidth))-\(category.rawValue)-state-\(index).png", as: .png)
    }
  }

  private func summary(progress: LibraryTaskProgress?) -> LibraryTodaySummary {
    .init(
      date: InterfaceFixtures.referenceDate, progress: progress, availability: .existing,
      excerpt: "Keep the next good thought. Leave room for a small adventure.")
  }

  private func frame(_ identifier: String, in window: UIWindow) -> CGRect? {
    func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    guard let view = descendants(window).first(where: {
      $0.accessibilityIdentifier == "capture-frame-\(identifier)"
        && !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty
        && $0.convert($0.bounds, to: window).intersects(window.bounds)
    }) else { return nil }
    return view.convert(view.bounds, to: window)
  }
}
