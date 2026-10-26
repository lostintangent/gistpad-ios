#if os(iOS)
import SwiftUI
import GistPadAppearance

public enum InterfaceTheme {
    public static let accent = Color(uiColor: AccentRole.text.uiColor)
    public static let selection = Color(uiColor: AccentRole.selectedSurface.uiColor)
    public static let neutralSelection = Color(uiColor: .tertiarySystemFill)
    public static let syntaxMuted = Color("SyntaxMuted", bundle: .module)
    public static let text = Color("Ink", bundle: .module)
    static let taskCompletion = taskInk(.systemGreen)
    static let overdue = taskInk(.systemOrange)

    private static func taskInk(_ color: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            guard let rgb = RGBColor(uiColor: color.resolvedColor(with: traits)) else {
                preconditionFailure("Native task colors must resolve to opaque RGB.")
            }
            return PersonalAccent(savedHex: rgb.hex).roles(traits: traits).text.uiColor
        })
    }
}

extension View {
    public func personalAccent(savedHex: String?) -> some View {
        environment(\.personalAccent, PersonalAccent(savedHex: savedHex))
    }
}

extension LibraryCollection {
    var title: String {
        switch self {
        case .gists: String(localized: "Your Gists", bundle: .module)
        case .dailyNotes: String(localized: "Daily Notes", bundle: .module)
        case .starred: String(localized: "Starred", bundle: .module)
        case .archive: String(localized: "Archive", bundle: .module)
        }
    }

    var symbol: String {
        switch self {
        case .gists: "doc.text"
        case .dailyNotes: "calendar"
        case .starred: "star"
        case .archive: "archivebox"
        }
    }
}

struct TagSwatch: View {
    let hex: String?
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(Self.color(hex: hex))
            .frame(width: size, height: size)
            .overlay {
                if let boundary {
                    Circle().strokeBorder(boundary, lineWidth: 0.5)
                }
            }
            .accessibilityHidden(true)
    }

    static func color(hex: String?) -> Color {
        guard let rgb = rgb(hex: hex) else { return .secondary }
        return Color(
            .sRGB, red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1
        )
    }

    private var boundary: Color? {
        guard let rgb = Self.rgb(hex: hex) else { return nil }
        let red = Double((rgb >> 16) & 255) / 255
        let green = Double((rgb >> 8) & 255) / 255
        let blue = Double(rgb & 255) / 255
        let brightness = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        if colorScheme == .light && brightness > 0.7 {
            return Color(.sRGB, red: red * 0.7, green: green * 0.7, blue: blue * 0.7, opacity: 1)
        }
        if colorScheme == .dark && brightness < 0.2 {
            return Color(
                .sRGB, red: red * 0.72 + 0.28,
                green: green * 0.72 + 0.28, blue: blue * 0.72 + 0.28, opacity: 1
            )
        }
        return nil
    }

    private static func rgb(hex: String?) -> UInt32? {
        guard let hex else { return nil }
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6 else { return nil }
        return UInt32(value, radix: 16)
    }
}
#endif
