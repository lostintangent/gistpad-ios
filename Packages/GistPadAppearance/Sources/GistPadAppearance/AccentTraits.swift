#if os(iOS)
import SwiftUI
import UIKit

public struct PersonalAccentTrait: UITraitDefinition {
    public static let defaultValue = PersonalAccent()
    public static let affectsColorAppearance = true
}

private struct PersonalAccentEnvironmentKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = PersonalAccent()

    static func read(from traitCollection: UITraitCollection) -> PersonalAccent {
        traitCollection[PersonalAccentTrait.self]
    }

    static func write(to mutableTraits: inout any UIMutableTraits, value: PersonalAccent) {
        mutableTraits[PersonalAccentTrait.self] = value
    }
}

extension EnvironmentValues {
    public var personalAccent: PersonalAccent {
        get { self[PersonalAccentEnvironmentKey.self] }
        set { self[PersonalAccentEnvironmentKey.self] = newValue }
    }

    /// Whether the editor or preview pane is the one on screen.
    @Entry public var isNotebookPaneVisible = true
}

extension RGBColor {
    public var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    public init?(uiColor: UIColor) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let color = uiColor.cgColor.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              color.alpha == 1, let components = color.components, components.count == 4 else { return nil }
        self.init(
            red: UInt8((min(1, max(0, components[0])) * 255).rounded()),
            green: UInt8((min(1, max(0, components[1])) * 255).rounded()),
            blue: UInt8((min(1, max(0, components[2])) * 255).rounded())
        )
    }
}

extension PersonalAccent {
    public func roles(traits: UITraitCollection) -> AccentRoles {
        let dark = traits.userInterfaceStyle == .dark
        let increased = traits.accessibilityContrast == .high
        let backgrounds: [UIColor] = [
            .systemBackground, .secondarySystemBackground, .tertiarySystemBackground,
            .systemGroupedBackground, .secondarySystemGroupedBackground, .tertiarySystemGroupedBackground
        ]
        let surfaces = backgrounds.map { color in
            guard let rgb = RGBColor(uiColor: color.resolvedColor(with: traits)) else {
                preconditionFailure("System page surfaces must resolve to opaque RGB.")
            }
            return rgb
        }
        return roles(dark: dark, increasedContrast: increased, surfaces: surfaces)
    }
}

public enum AccentRole: Sendable {
    case text

    public var uiColor: UIColor {
        UIColor { traits in traits[PersonalAccentTrait.self].roles(traits: traits).text.uiColor }
    }
}
#endif
