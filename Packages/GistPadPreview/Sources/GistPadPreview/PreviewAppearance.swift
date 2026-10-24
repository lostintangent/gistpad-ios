#if os(iOS)
import UIKit
import GistPadAppearance

struct PreviewAppearance: Equatable {
    let variables: [String: String]
    let increasedContrast: Bool
    let boldText: Bool
    let colorScheme: String

    @MainActor
    init(traits: UITraitCollection, boldText: Bool? = nil) {
        increasedContrast = traits.accessibilityContrast == .high
        self.boldText = boldText ?? UIAccessibility.isBoldTextEnabled
        let dark = traits.userInterfaceStyle == .dark
        colorScheme = dark ? "dark" : "light"
        let accent = traits[PersonalAccentTrait.self].roles(traits: traits)
        let code = increasedContrast ? (dark ? "#F1F5F9" : "#334155") : (dark ? "#CBD5E1" : "#475569")
        var values = [
            "--gp-page": Self.css(UIColor.systemBackground.resolvedColor(with: traits)),
            "--gp-surface": Self.css(UIColor.secondarySystemBackground.resolvedColor(with: traits)),
            "--gp-surface-raised": Self.css(UIColor.tertiarySystemBackground.resolvedColor(with: traits)),
            "--gp-text": Self.css(UIColor.label.resolvedColor(with: traits)),
            "--gp-syntax-code": code,
            "--gp-text-secondary": Self.css(UIColor.secondaryLabel.resolvedColor(with: traits)),
            "--gp-link": Self.css(UIColor.link.resolvedColor(with: traits)),
            "--gp-separator": Self.css(UIColor.separator.resolvedColor(with: traits)),
            "--gp-boundary": Self.css(UIColor.opaqueSeparator.resolvedColor(with: traits)),
            "--gp-error": Self.css(UIColor.systemRed.resolvedColor(with: traits)),
            "--gp-success": Self.css(UIColor.systemGreen.resolvedColor(with: traits)),
            "--gp-accent-text": accent.text.hex,
            "--gp-accent-fill": accent.fill.hex,
            "--gp-on-accent": accent.onFill.hex,
            "--gp-selected-surface": accent.selectedSurface.hex
        ]
        let styles: [(String, UIFont.TextStyle)] = [
            ("body", .body), ("title1", .title1), ("title2", .title2),
            ("title3", .title3), ("headline", .headline), ("footnote", .footnote)
        ]
        for (name, style) in styles {
            let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            values["--gp-\(name)-size"] = "\(font.pointSize)px"
            values["--gp-\(name)-line-height"] = "\(font.lineHeight)px"
        }
        values["--gp-code-size"] = values["--gp-body-size"]
        variables = values
    }

    var arguments: [String: Any] {
        ["variables": variables, "increasedContrast": increasedContrast, "boldText": boldText, "colorScheme": colorScheme]
    }

    private static func css(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return "rgba(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())),\(alpha))"
    }
}
#endif
