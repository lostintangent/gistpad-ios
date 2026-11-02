import SwiftUI
import Testing
@testable import GistPadAccent

// macOS QuickDraw also declares an `RGBColor`.
private typealias RGBColor = GistPadAccent.RGBColor

struct AccentTests {
    @Test("A picked color saves as the web's sRGB hex")
    func pickedColor() {
        let picked = Color(.sRGB, red: 250 / 255, green: 204 / 255, blue: 21 / 255)
        #expect(RGBColor(picked.resolve(in: EnvironmentValues())).hex == "#FACC15")
        #expect(Accent(savedHex: "#facc15").color.hex == "#FACC15")
        #expect(Accent(savedHex: "yellow").color == .sky)
    }

    @Test("Any saved accent keeps accent text readable in Light and Dark", arguments: ["#FEF08A", "#1E3A8A"])
    func readableText(hex: String) {
        for dark in [false, true] {
            let page: RGBColor = dark ? .black : .white
            let surface = RGBColor(hex: dark ? "#2C2C2E" : "#F2F2F7")!
            let roles = Accent(savedHex: hex)
                .roles(dark: dark, increasedContrast: false, surfaces: [page, surface])
            #expect(roles.text.contrast(with: page) >= 4.5)
            #expect(roles.text.contrast(with: surface) >= 4.5)
        }
    }
}
