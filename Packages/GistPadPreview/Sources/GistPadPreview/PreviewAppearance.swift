#if os(iOS)
import OSLog
import UIKit

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
        let accent = increasedContrast ? (dark ? "#BAE6FD" : "#075985") : (dark ? "#7DD3FC" : "#0369A1")
        let fill = increasedContrast ? (dark ? "#7DD3FC" : "#0EA5E9") : (dark ? "#38BDF8" : "#0EA5E9")
        let selected = increasedContrast ? (dark ? "#134B63" : "#D4EEFC") : (dark ? "#0B3548" : "#E7F6FD")
        let ink = increasedContrast ? (dark ? "#F8FAFC" : "#0F172A") : (dark ? "#E2E8F0" : "#1E293B")
        let code = increasedContrast ? (dark ? "#F1F5F9" : "#334155") : (dark ? "#CBD5E1" : "#475569")
        var values = [
            "--gp-page": Self.css(UIColor.systemBackground.resolvedColor(with: traits)),
            "--gp-surface": Self.css(UIColor.secondarySystemBackground.resolvedColor(with: traits)),
            "--gp-surface-raised": Self.css(UIColor.tertiarySystemBackground.resolvedColor(with: traits)),
            "--gp-text": ink,
            "--gp-syntax-code": code,
            "--gp-text-secondary": Self.css(UIColor.secondaryLabel.resolvedColor(with: traits)),
            "--gp-link": Self.css(UIColor.link.resolvedColor(with: traits)),
            "--gp-separator": Self.css(UIColor.separator.resolvedColor(with: traits)),
            "--gp-boundary": Self.css(UIColor.opaqueSeparator.resolvedColor(with: traits)),
            "--gp-error": Self.css(UIColor.systemRed.resolvedColor(with: traits)),
            "--gp-success": Self.css(UIColor.systemGreen.resolvedColor(with: traits)),
            "--gp-accent-text": accent,
            "--gp-accent-fill": fill,
            "--gp-on-accent": "#0F172A",
            "--gp-selected-surface": selected
        ]
        let styles: [(String, UIFont.TextStyle)] = [
            ("body", .body), ("title1", .title1), ("title2", .title2),
            ("title3", .title3), ("headline", .headline), ("footnote", .footnote)
        ]
        for (name, style) in styles {
            var font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
            if name == "title1" || name == "title2" {
                if let descriptor = font.fontDescriptor.withDesign(.serif) {
                    font = UIFont(descriptor: descriptor, size: font.pointSize)
                } else {
                    Logger(subsystem: "dev.gistpad.GistPad", category: "MarkdownPreview")
                        .error("The system serif heading descriptor was unavailable.")
                }
            }
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
