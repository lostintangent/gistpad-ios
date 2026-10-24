#if os(iOS)
import SwiftUI

public enum InterfaceTheme {
    public static let accent = Color("AccentText", bundle: .module)
    public static let selection = Color("SelectedSurface", bundle: .module)
    public static let text = Color(uiColor: .label)
}

extension LibraryCollection {
    var title: String {
        switch self {
        case .gists: String(localized: "Notes", bundle: .module)
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

    var body: some View {
        Circle()
            .fill(Self.color(hex: hex))
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(.primary, lineWidth: 0.75) }
            .accessibilityHidden(true)
    }

    static func color(hex: String?) -> Color {
        guard let hex else { return .secondary }
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return .secondary }
        return Color(
            .sRGB, red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1
        )
    }
}
#endif
