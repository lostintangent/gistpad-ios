#if os(iOS)
import Testing
import UIKit
import GistPadAppearance
@testable import GistPadPreview

@MainActor
struct PreviewAppearanceTests {
    @Test("The preview uses shared personal accent roles without recoloring the reading ink")
    func contentPalette() {
        let expected = [
            ["#1E293B", "#475569"],
            ["#E2E8F0", "#CBD5E1"],
            ["#0F172A", "#334155"],
            ["#F8FAFC", "#F1F5F9"]
        ]
        let roles = ["--gp-text", "--gp-syntax-code"]
        for (index, colors) in expected.enumerated() {
            for savedHex in [nil, "#FACC15", "#FFFFFF", "#000000", "#FF00FF", "invalid"] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = index % 2 == 0 ? .light : .dark
                    $0.accessibilityContrast = index >= 2 ? .high : .normal
                    $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: savedHex)
                }
                let appearance = PreviewAppearance(traits: traits)
                let shared = PersonalAccent(savedHex: savedHex).roles(traits: traits)
                #expect(roles.compactMap { appearance.variables[$0] } == colors)
                #expect(appearance.variables["--gp-accent-text"] == shared.text.hex)
                #expect(appearance.variables["--gp-accent-fill"] == shared.fill.hex)
                #expect(appearance.variables["--gp-on-accent"] == shared.onFill.hex)
                #expect(appearance.variables["--gp-selected-surface"] == shared.selectedSurface.hex)
                #expect(appearance.variables["--gp-link"]?.hasPrefix("rgba(") == true)
            }
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
