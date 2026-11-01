#if os(iOS)
import Testing
@testable import GistPadInterface

struct TagContrastTests {
    @Test func whiteAndBlackFillsUseTheOppositeInk() {
        #expect(TagContrast.prefersBlackInk(luminance: TagContrast.relativeLuminance(0xFFFFFF)))
        #expect(!TagContrast.prefersBlackInk(luminance: TagContrast.relativeLuminance(0x000000)))
    }

    @Test func lightAndDarkHuesPickTheHigherContrastInk() {
        #expect(TagContrast.prefersBlackInk(luminance: TagContrast.relativeLuminance(0xEBC85A)))
        #expect(!TagContrast.prefersBlackInk(luminance: TagContrast.relativeLuminance(0x1E3A8A)))
    }

    @Test func everySampledSavedColorReachesFourPointFiveWithChosenInk() {
        var failures: [UInt32] = []
        for red in stride(from: 0, through: 255, by: 17) {
            for green in stride(from: 0, through: 255, by: 17) {
                for blue in stride(from: 0, through: 255, by: 17) {
                    let rgb = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
                    let luminance = TagContrast.relativeLuminance(rgb)
                    let inkLuminance = TagContrast.prefersBlackInk(luminance: luminance) ? 0.0 : 1.0
                    if TagContrast.contrastRatio(luminance, inkLuminance) < 4.5 {
                        failures.append(rgb)
                    }
                }
            }
        }
        #expect(failures.isEmpty)
    }

    @Test func missingOrMalformedColorHasNoSavedRGB() {
        #expect(TagSwatch.rgb(hex: nil) == nil)
        #expect(TagSwatch.rgb(hex: "#FFF") == nil)
        #expect(TagSwatch.rgb(hex: "#EBC85A") == 0xEBC85A)
    }
}
#endif
