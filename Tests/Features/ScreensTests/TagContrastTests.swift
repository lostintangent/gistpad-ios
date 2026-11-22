#if os(iOS)
import Appearance
import SwiftUI
import Testing
@testable import Screens

struct TagContrastTests {
    @Test func aTagPicksTheHigherContrastInkAndAMissingColorUsesTheNeutralFill() {
        #expect(RGBColor(tagHex: "#FFFFFF")?.contrastingInk == .black)
        #expect(RGBColor(tagHex: "EBC85A")?.contrastingInk == .black)
        #expect(RGBColor(tagHex: "#1E3A8A")?.contrastingInk == .white)
        #expect(RGBColor(tagHex: "#000000")?.contrastingInk == .white)
        for missing in [nil, "", "yellow", "#12345678"] {
            #expect(RGBColor(tagHex: missing) == nil)
        }
    }
}
#endif
