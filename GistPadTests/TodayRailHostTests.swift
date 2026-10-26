import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct TodayRailHostTests {
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
  func todayRemainsOneNativeActionAcrossUnknownZeroAndLargeCounts(
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
      summary(progress: .init(completed: 0, total: 104)),
      .init(date: InterfaceFixtures.referenceDate, availability: .missing),
    ]
    var activations = 0
    func content(_ index: Int) -> some View {
      NavigationStack {
        Color(uiColor: .systemBackground)
          .navigationTitle("GistPad")
          .libraryRail(
            isVisible: true, today: summaries[index], isTodaySelected: true,
            create: {}, openToday: { activations += 1 })
      }
      .frame(width: cardWidth)
      .personalAccent(savedHex: "#FACC15")
    }
    let host = UIHostingController(rootView: content(0))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    for index in summaries.indices {
      host.rootView = content(index)
      try await Task.sleep(for: .milliseconds(350))
      window.layoutIfNeeded()
      let controls = descendants(window).compactMap { $0 as? UIControl }.filter {
        $0.accessibilityIdentifier == "library-today" && !$0.isHidden && $0.alpha > 0
      }
      #expect(controls.count == 1)
      let control = try #require(controls.first)
      let target = control.convert(control.bounds, to: window)
      #expect(window.bounds.contains(target))
      let hitRegion = CGRect(
        x: target.midX - 22, y: target.midY - 22, width: 44, height: 44)
      for point in [
        CGPoint(x: hitRegion.minX + 1, y: hitRegion.midY),
        CGPoint(x: hitRegion.maxX - 1, y: hitRegion.midY),
        CGPoint(x: hitRegion.midX, y: hitRegion.minY + 1),
        CGPoint(x: hitRegion.midX, y: hitRegion.maxY - 1)
      ] {
        let hit = try #require(window.hitTest(point, with: nil))
        #expect(hit === control || hit.isDescendant(of: control))
      }
      if let count = summaries[index].unfinishedTaskCount, count > 0 {
        #expect(control.accessibilityValue?.contains(count.formatted()) == true)
      }
      control.performPrimaryAction()
      #expect(activations == index + 1)
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      Attachment.record(
        image, named: "today-rail-\(Int(cardWidth))-\(category.rawValue)-state-\(index).png", as: .png)
    }
  }

  private func summary(progress: LibraryTaskProgress?) -> LibraryTodaySummary {
    .init(
      date: InterfaceFixtures.referenceDate, progress: progress, availability: .existing,
      excerpt: "Keep the next good thought. Leave room for a small adventure.")
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
