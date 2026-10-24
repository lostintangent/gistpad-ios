import Testing
@testable import GistPadAppearance

struct PersonalAccentTests {
    @Test("Saved RGB is preserved and invalid values remain distinguishable from a missing value")
    func parsing() {
        #expect(PersonalAccent().color == .sky)
        #expect(!PersonalAccent().isInvalid)
        for hex in ["#facc15", "#FFFFFF", "#000000", "#abc"] {
            let accent = PersonalAccent(savedHex: hex)
            #expect(accent.savedHex == hex)
            #expect(!accent.isInvalid)
        }
        #expect(PersonalAccent(savedHex: "#facc15").color.hex == "#FACC15")
        for invalid in ["", "yellow", "facc15", "#ff", "#12345678", "#12zz45", "#+12345"] {
            let accent = PersonalAccent(savedHex: invalid)
            #expect(accent.isInvalid)
            #expect(accent.savedHex == invalid)
            #expect(accent.color == .sky)
        }
    }

    @Test("Every role satisfies its final quantized contrast in all four appearances")
    func contrast() {
        let samples = [
            "#FACC15", "#FFFFFF", "#000000", "#FF0000", "#00FF00", "#0000FF",
            "#FF00FF", "#00FFFF", "#808080", "#0EA5E9"
        ]
        for dark in [false, true] {
            for increased in [false, true] {
                let target = increased ? 7.0 : 4.5
                let page: RGBColor = dark ? .black : .white
                let surface = RGBColor(hex: dark ? "#2C2C2E" : "#F2F2F7")!
                let ink = RGBColor(hex: dark ? "#E2E8F0" : "#1E293B")!
                for hex in samples {
                    let accent = PersonalAccent(savedHex: hex)
                    let roles = accent.roles(
                        dark: dark, increasedContrast: increased,
                        surfaces: [page, surface], selectionSurface: surface, ink: ink
                    )
                    #expect(roles.text.contrast(with: page) >= target, "\(hex)/\(dark)/\(increased)")
                    #expect(roles.text.contrast(with: surface) >= target, "\(hex)/\(dark)/\(increased)")
                    #expect(roles.fill.contrast(with: roles.onFill) >= target, "\(hex)/\(dark)/\(increased)")
                    #expect(roles.selectedSurface.contrast(with: ink) >= target, "\(hex)/\(dark)/\(increased)")
                    if !increased { #expect(roles.fill == accent.color) }
                    #expect(accent.savedHex == hex)
                }
            }
        }
    }

    @Test("Luminance uses linearized sRGB rather than brightness")
    func luminance() {
        #expect(RGBColor.black.contrast(with: .white) == 21)
        let green = RGBColor(hex: "#22863A")!
        #expect(green.contrast(with: .white) > 4.5)
        #expect(green.contrast(with: RGBColor(hex: "#F2F2F7")!) < 4.5)
    }
}
