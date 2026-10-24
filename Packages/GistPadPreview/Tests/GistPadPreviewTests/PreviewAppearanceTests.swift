#if os(iOS)
import Testing
import UIKit
import GistPadAppearance
@testable import GistPadPreview

@MainActor
struct PreviewAppearanceTests {
    @Test("The preview uses shared personal accent roles without recoloring the reading ink")
    func contentPalette() {
        for (index, code) in ["#475569", "#CBD5E1", "#334155", "#F1F5F9"].enumerated() {
            for savedHex in [nil, "#FACC15", "#FFFFFF", "#000000", "#FF00FF", "invalid"] {
                let traits = UITraitCollection {
                    $0.userInterfaceStyle = index % 2 == 0 ? .light : .dark
                    $0.accessibilityContrast = index >= 2 ? .high : .normal
                    $0[PersonalAccentTrait.self] = PersonalAccent(savedHex: savedHex)
                }
                let appearance = PreviewAppearance(traits: traits)
                let shared = PersonalAccent(savedHex: savedHex).roles(traits: traits)
                let label = UIColor.label.resolvedColor(with: traits)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                #expect(label.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                #expect(appearance.variables["--gp-text"] ==
                    "rgba(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())),\(alpha))")
                #expect(appearance.variables["--gp-syntax-code"] == code)
                #expect(appearance.variables["--gp-accent-text"] == shared.text.hex)
                #expect(appearance.variables["--gp-accent-fill"] == shared.fill.hex)
                #expect(appearance.variables["--gp-on-accent"] == shared.onFill.hex)
                #expect(appearance.variables["--gp-selected-surface"] == shared.selectedSurface.hex)
                #expect(appearance.variables["--gp-link"]?.hasPrefix("rgba(") == true)
            }
        }
    }

    @Test("Heading sizes preserve Large and follow native text-style point growth at every category")
    func systemHeadingMetrics() {
        let largeTraits = UITraitCollection { $0.preferredContentSizeCategory = .large }
        let categories: [UIContentSizeCategory] = [
            .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
            .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge
        ]
        for size in categories {
            let traits = UITraitCollection { $0.preferredContentSizeCategory = size }
            let appearance = PreviewAppearance(traits: traits)
            let headings: [(String, UIFont.TextStyle, CGFloat)] = [
                ("title1", .largeTitle, 34), ("title2", .title2, 25.5), ("title3", .title3, 21.25)
            ]
            for (name, style, largeSize) in headings {
                let preferred = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
                let reference = UIFont.preferredFont(forTextStyle: style, compatibleWith: largeTraits)
                let expectedSize = largeSize + preferred.pointSize - reference.pointSize
                let font = UIFont(descriptor: preferred.fontDescriptor, size: expectedSize)
                #expect(appearance.variables["--gp-\(name)-size"] == "\(font.pointSize)px")
                #expect(appearance.variables["--gp-\(name)-line-height"] == "\(font.lineHeight)px")
            }
        }
    }
}
#endif
