#if os(iOS)
import SwiftUI
import Testing
@testable import Interface

struct TagContrastTests {
    @Test func aTagPicksTheHigherContrastInkAndAMissingColorUsesTheNeutralFill() {
        #expect(TagLabelStyle(hex: "#FFFFFF").ink == .black)
        #expect(TagLabelStyle(hex: "EBC85A").ink == .black)
        #expect(TagLabelStyle(hex: "#1E3A8A").ink == .white)
        #expect(TagLabelStyle(hex: "#000000").ink == .white)
        for missing in [nil, "", "yellow", "#12345678"] {
            #expect(TagLabelStyle(hex: missing).ink == .primary)
            #expect(TagLabelStyle(hex: missing).edge == nil)
        }
    }
}
#endif
