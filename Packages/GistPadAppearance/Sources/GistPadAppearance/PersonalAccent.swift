import Foundation

public struct RGBColor: Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        guard hex.first == "#" else { return nil }
        let digits = Array(hex.dropFirst().utf8)
        guard [3, 6].contains(digits.count),
              digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        let expanded = digits.count == 3 ? digits.flatMap { [$0, $0] } : digits
        guard let value = UInt32(String(decoding: expanded, as: UTF8.self), radix: 16) else { return nil }
        self.init(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 255, green: 255, blue: 255)
    public static let sky = RGBColor(red: 14, green: 165, blue: 233)

    public var hex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    public var luminance: Double {
        func linear(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: RGBColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    public func mixed(toward other: RGBColor, amount: Double) -> RGBColor {
        let amount = min(1, max(0, amount))
        func component(_ start: UInt8, _ end: UInt8) -> UInt8 {
            UInt8((Double(start) * (1 - amount) + Double(end) * amount).rounded())
        }
        return RGBColor(red: component(red, other.red), green: component(green, other.green), blue: component(blue, other.blue))
    }
}

public struct AccentRoles: Equatable, Sendable {
    public let text: RGBColor
    public let fill: RGBColor
    public let onFill: RGBColor
    public let selectedSurface: RGBColor
}

public struct PersonalAccent: Hashable, Sendable {
    public let savedHex: String?
    public let color: RGBColor
    public var isInvalid: Bool { savedHex.map { RGBColor(hex: $0) == nil } ?? false }

    public init(savedHex: String? = nil) {
        self.savedHex = savedHex
        color = savedHex.flatMap(RGBColor.init(hex:)) ?? .sky
    }

    public func roles(
        dark: Bool, increasedContrast: Bool, surfaces: [RGBColor],
        selectionSurface: RGBColor, ink: RGBColor
    ) -> AccentRoles {
        precondition(!surfaces.isEmpty)
        let target = increasedContrast ? 7.0 : 4.5
        let endpoint: RGBColor = dark ? .white : .black
        let text = passingMix(toward: endpoint) { color in
            surfaces.allSatisfy { color.contrast(with: $0) >= target }
        }.color
        let onOriginal: RGBColor = color.contrast(with: .black) >= color.contrast(with: .white) ? .black : .white
        let fill: RGBColor
        let onFill: RGBColor
        if color.contrast(with: onOriginal) >= target {
            fill = color
            onFill = onOriginal
        } else {
            let darker = passingMix(toward: .black) { $0.contrast(with: .white) >= target }
            let lighter = passingMix(toward: .white) { $0.contrast(with: .black) >= target }
            fill = darker.amount <= lighter.amount ? darker.color : lighter.color
            onFill = darker.amount <= lighter.amount ? .white : .black
        }
        var tint = increasedContrast ? 0.20 : 0.12
        var selected = selectionSurface.mixed(toward: color, amount: tint)
        while ink.contrast(with: selected) < target && tint > 0 {
            tint = max(0, tint - 0.01)
            selected = selectionSurface.mixed(toward: color, amount: tint)
        }
        precondition(ink.contrast(with: selected) >= target)
        return AccentRoles(text: text, fill: fill, onFill: onFill, selectedSurface: selected)
    }

    private func passingMix(toward endpoint: RGBColor, passes: (RGBColor) -> Bool) -> (color: RGBColor, amount: Double) {
        if passes(color) { return (color, 0) }
        precondition(passes(endpoint))
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<32 {
            let middle = (lower + upper) / 2
            if passes(color.mixed(toward: endpoint, amount: middle)) { upper = middle }
            else { lower = middle }
        }
        return (color.mixed(toward: endpoint, amount: upper), upper)
    }
}
