#if os(iOS)
import SwiftUI
import UIKit

public struct AccentTrait: UITraitDefinition {
    public static let defaultValue = Accent()
    public static let affectsColorAppearance = true
}

private struct AccentEnvironmentKey: UITraitBridgedEnvironmentKey {
    static let defaultValue = Accent()

    static func read(from traitCollection: UITraitCollection) -> Accent {
        traitCollection[AccentTrait.self]
    }

    static func write(to mutableTraits: inout any UIMutableTraits, value: Accent) {
        mutableTraits[AccentTrait.self] = value
    }
}

extension EnvironmentValues {
    public var accent: Accent {
        get { self[AccentEnvironmentKey.self] }
        set { self[AccentEnvironmentKey.self] = newValue }
    }

    /// Whether the editor or preview pane is the one on screen.
    @Entry public var isPaneVisible = true
}

extension View {
    public func accent(savedHex: String?) -> some View {
        environment(\.accent, Accent(savedHex: savedHex))
    }
}

extension RGBColor {
    public var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// An opaque color's sRGB, for the traits it was resolved with.
    public init(uiColor: UIColor) { self.init(Color(uiColor: uiColor).resolve(in: EnvironmentValues())) }
}

extension Accent {
    public func roles(traits: UITraitCollection) -> Roles {
        let dark = traits.userInterfaceStyle == .dark
        let increased = traits.accessibilityContrast == .high
        let backgrounds: [UIColor] = [
            .systemBackground, .secondarySystemBackground, .tertiarySystemBackground,
            .systemGroupedBackground, .secondarySystemGroupedBackground, .tertiarySystemGroupedBackground
        ]
        return roles(
            dark: dark, increasedContrast: increased,
            surfaces: backgrounds.map { RGBColor(uiColor: $0.resolvedColor(with: traits)) })
    }
}

extension UIColor {
    /// The personal accent's text color for the current traits.
    public static let accentText = UIColor { traits in
        traits[AccentTrait.self].roles(traits: traits).text.uiColor
    }
}
#endif
