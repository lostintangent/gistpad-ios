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
        let marker = Self.listMarker(traits: traits)
        var values = [
            "--gp-page": Self.css(UIColor.systemBackground.resolvedColor(with: traits)),
            "--gp-surface": Self.css(UIColor.secondarySystemBackground.resolvedColor(with: traits)),
            "--gp-surface-raised": Self.css(UIColor.tertiarySystemBackground.resolvedColor(with: traits)),
            "--gp-text": Self.css(UIColor.label.resolvedColor(with: traits)),
            "--gp-syntax-code": code,
            "--gp-text-secondary": Self.css(UIColor.secondaryLabel.resolvedColor(with: traits)),
            "--gp-list-marker": marker,
            "--gp-list-bullet": increasedContrast ? marker : (dark ? "#525252" : "#D4D4D4"),
            "--gp-list-number": increasedContrast ? marker : (dark ? "#A1A1A1" : "#737373"),
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
            ("body", .body), ("headline", .headline), ("footnote", .footnote)
        ]
        for (name, style) in styles {
            let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            values["--gp-\(name)-size"] = "\(font.pointSize)px"
            values["--gp-\(name)-line-height"] = "\(font.lineHeight)px"
        }
        let largeTraits = UITraitCollection { $0.preferredContentSizeCategory = .large }
        let largeBody = UIFont.preferredFont(forTextStyle: .body, compatibleWith: largeTraits)
        let headings: [(String, UIFont.TextStyle, CGFloat)] = [
            ("title1", .largeTitle, 2), ("title2", .title2, 1.5), ("title3", .title3, 1.25)
        ]
        for (name, style, largeRatio) in headings {
            let preferred = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            let reference = UIFont.preferredFont(forTextStyle: style, compatibleWith: largeTraits)
            // Preserve the approved Large baseline and UIKit's per-style point growth.
            let size = largeBody.pointSize * largeRatio + preferred.pointSize - reference.pointSize
            let font = UIFont(descriptor: preferred.fontDescriptor, size: size)
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

    private static func listMarker(traits: UITraitCollection) -> String {
        let secondary = UIColor.secondaryLabel.resolvedColor(with: traits)
        guard let page = RGBColor(uiColor: UIColor.systemBackground.resolvedColor(with: traits)),
              let ink = RGBColor(uiColor: UIColor.label.resolvedColor(with: traits)),
              let gray = RGBColor(uiColor: secondary.withAlphaComponent(1))
        else { preconditionFailure("Native list-marker colors must resolve to sRGB.") }
        let original = page.mixed(toward: gray, amount: Double(secondary.cgColor.alpha))
        let minimum = traits.accessibilityContrast == .high ? 7.0 : 4.5
        for step in 0...255 {
            let candidate = original.mixed(toward: ink, amount: Double(step) / 255)
            if candidate.contrast(with: page) >= minimum { return candidate.hex }
        }
        preconditionFailure("Native label ink must meet list-marker contrast against its page.")
    }
}
#endif
