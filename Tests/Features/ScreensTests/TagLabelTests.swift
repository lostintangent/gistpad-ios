#if os(iOS)
import Appearance
import Store
import SwiftUI
import Testing
@testable import Screens

@MainActor
struct TagLabelTests {
    @Test func aTagPicksTheHigherContrastInkAndAMissingColorUsesTheNeutralFill() {
        #expect(RGBColor(tagHex: "#FFFFFF")?.contrastingInk == .black)
        #expect(RGBColor(tagHex: "EBC85A")?.contrastingInk == .black)
        #expect(RGBColor(tagHex: "#1E3A8A")?.contrastingInk == .white)
        #expect(RGBColor(tagHex: "#000000")?.contrastingInk == .white)
        for missing in [nil, "", "yellow", "#12345678"] {
            #expect(RGBColor(tagHex: missing) == nil)
        }
    }

    @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
    func wrappedTagsStartAtTheLeadingEdge(direction: LayoutDirection) throws {
        let renderer = ImageRenderer(content: TagLabels(tags: [Tag(id: "red", name: "red", colorHex: "#FF0000")])
            .frame(width: 200)
            .environment(\.layoutDirection, direction))
        renderer.scale = 1
        let columns = try redColumns(in: #require(renderer.cgImage))
        #expect(!columns.isEmpty)
        #expect(columns.allSatisfy { ($0 < 100) == (direction == .leftToRight) })
    }

    /// The columns whose middle pixel is the red tag's fill.
    private func redColumns(in image: CGImage) throws -> [Int] {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let row = image.height / 2 * image.width * 4
        return (0..<image.width).filter {
            pixels[row + $0 * 4] > 200 && pixels[row + $0 * 4 + 1] < 60 && pixels[row + $0 * 4 + 2] < 60
        }
    }
}
#endif
