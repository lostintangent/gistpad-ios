#if os(iOS)
import Testing
import UIKit
@testable import GistPadPreview

@MainActor
struct PreviewAppearanceTests {
    @Test("The preview uses the four icon-led content palettes")
    func contentPalette() {
        let expected = [
            ["#1E293B", "#0369A1", "#0EA5E9", "#E7F6FD", "#475569"],
            ["#E2E8F0", "#7DD3FC", "#38BDF8", "#0B3548", "#CBD5E1"],
            ["#0F172A", "#075985", "#0EA5E9", "#D4EEFC", "#334155"],
            ["#F8FAFC", "#BAE6FD", "#7DD3FC", "#134B63", "#F1F5F9"]
        ]
        let roles = ["--gp-text", "--gp-accent-text", "--gp-accent-fill", "--gp-selected-surface", "--gp-syntax-code"]
        for (index, colors) in expected.enumerated() {
            let traits = UITraitCollection {
                $0.userInterfaceStyle = index % 2 == 0 ? .light : .dark
                $0.accessibilityContrast = index >= 2 ? .high : .normal
            }
            let appearance = PreviewAppearance(traits: traits)
            #expect(roles.compactMap { appearance.variables[$0] } == colors)
            #expect(appearance.variables["--gp-on-accent"] == "#0F172A")
            #expect(appearance.variables["--gp-link"]?.hasPrefix("rgba(") == true)
        }
    }

    @Test("Rendered heading metrics follow native system serif at Large and AX3")
    func serifHeadingMetrics() throws {
        for size: UIContentSizeCategory in [.large, .accessibilityExtraLarge] {
            let traits = UITraitCollection { $0.preferredContentSizeCategory = size }
            let appearance = PreviewAppearance(traits: traits)
            for (name, style): (String, UIFont.TextStyle) in [("title1", .title1), ("title2", .title2)] {
                let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                let descriptor = try #require(base.fontDescriptor.withDesign(.serif))
                let serif = UIFont(descriptor: descriptor, size: base.pointSize)
                #expect(appearance.variables["--gp-\(name)-size"] == "\(serif.pointSize)px")
                #expect(appearance.variables["--gp-\(name)-line-height"] == "\(serif.lineHeight)px")
            }
        }
    }
}
#endif
