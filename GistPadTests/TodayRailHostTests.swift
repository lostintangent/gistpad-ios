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

}
