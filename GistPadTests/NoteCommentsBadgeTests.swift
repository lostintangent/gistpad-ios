import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@MainActor
struct NoteCommentsBadgeTests {
  @Test(arguments: [false, true], [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func countsUseReadableNeutralInkInsideTheSameIconBounds(
    dark: Bool, category: UIContentSizeCategory
  ) throws {
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let size = min(13, UIFontMetrics(forTextStyle: .caption2).scaledValue(
      for: 11, compatibleWith: traits))
    let initial = NoteCommentsIcon.image(count: nil, fontSize: size, dark: dark, scale: 3)
    #expect(initial.size == CGSize(width: 36, height: 36))
    for count in [24, 1, 124, 0] {
      let icon = NoteCommentsIcon.image(count: count, fontSize: size, dark: dark, scale: 3)
      #expect(icon.size == initial.size)
      #expect(icon.renderingMode == .alwaysOriginal)
      let alignment = CGRect(origin: .zero, size: icon.size).inset(by: icon.alignmentRectInsets)
      try expectBubbleCentered(icon, on: alignment.midX)
      #expect(abs(alignment.midY - 21) <= 1)
      if count == 0 {
        #expect(icon.pngData() == initial.pngData(), "Unknown and zero totals have no visual count.")
      } else {
        #expect(icon.pngData() != initial.pngData())
        try expectNeutralCount(icon)
      }
      Attachment.record(
        icon, named: "comments-icon-\(count)-\(dark ? "Dark" : "Light")-\(category.rawValue).png",
        as: .png)
    }
  }

  private func expectBubbleCentered(_ image: UIImage, on axis: CGFloat) throws {
    let bitmap = try #require(image.cgImage?.cropping(to: CGRect(
      x: 0, y: 17 * image.scale, width: image.size.width * image.scale,
      height: (image.size.height - 17) * image.scale)))
    var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
        bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    }
    var columns: [Int] = []
    for y in 0..<bitmap.height {
      for x in 0..<bitmap.width where pixels[(y * bitmap.width + x) * 4 + 3] > 200 {
        columns.append(x)
      }
    }
    let first = try #require(columns.min())
    let last = try #require(columns.max())
    let center = CGFloat(first + last) / (2 * image.scale)
    #expect(abs(center - axis) <= 1, "The bubble, not its count, must center on the native toolbar axis.")
  }

  private func expectNeutralCount(_ image: UIImage) throws {
    let bitmap = try #require(image.cgImage?.cropping(to: CGRect(
      x: 0, y: 0, width: 36 * image.scale, height: 16 * image.scale)))
    var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
        bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    }
    let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 250 }
    #expect(!opaque.isEmpty)
    #expect(opaque.allSatisfy {
      abs(Int(pixels[$0]) - Int(pixels[$0 + 1])) <= 8
        && abs(Int(pixels[$0]) - Int(pixels[$0 + 2])) <= 8
    }, "The count must have neutral ink and a neutral background, never red.")
    let levels = opaque.map { Int(pixels[$0]) }
    #expect((levels.max() ?? 0) - (levels.min() ?? 0) >= 100)
  }
}
