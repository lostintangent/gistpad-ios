import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@MainActor
struct NoteCommentsBadgeTests {
  @Test(arguments: [false, true], [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func todayBadgeKeepsItsCalendarAxisAndCapsOnlyTheVisualCount(
    dark: Bool, category: UIContentSizeCategory
  ) throws {
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let size = min(13, UIFontMetrics(forTextStyle: .caption2).scaledValue(
      for: 11, compatibleWith: traits))
    for selected in [false, true] {
      func icon(_ count: Int?) -> UIImage {
        ToolbarBadgeIcon.image(
          systemImage: "calendar", count: count, fontSize: size,
          dark: dark, scale: 3, isSelected: selected)
      }
      let initial = icon(nil)
      #expect(initial.size == CGSize(width: 36, height: 36))
      #expect(icon(0).pngData() == initial.pngData())
      #expect(icon(100).pngData() == icon(104).pngData())
      #expect(icon(99).pngData() != icon(100).pngData())
      for count in [3, 99, 104] {
        let image = icon(count)
        #expect(image.size == initial.size)
        #expect(image.alignmentRectInsets == initial.alignmentRectInsets)
        let alignment = CGRect(origin: .zero, size: image.size).inset(by: image.alignmentRectInsets)
        try expectBubbleCentered(image, on: alignment.midX, level: dark != selected ? 255 : 0)
        try expectForegroundCount(image, dark: dark)
      }
    }
  }

  @Test(arguments: [false, true], [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func countsUseForegroundFillAndInverseInkInsideTheSameIconBounds(
    dark: Bool, category: UIContentSizeCategory
  ) throws {
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let size = min(13, UIFontMetrics(forTextStyle: .caption2).scaledValue(
      for: 11, compatibleWith: traits))
    for selected in [false, true] {
      let initial = ToolbarBadgeIcon.image(
        systemImage: "text.bubble", count: nil, fontSize: size, dark: dark, scale: 3, isSelected: selected)
      #expect(initial.size == CGSize(width: 36, height: 36))
      for count in [24, 1, 124, 0] {
        let icon = ToolbarBadgeIcon.image(
          systemImage: "text.bubble", count: count, fontSize: size,
          dark: dark, scale: 3, isSelected: selected)
        #expect(icon.size == initial.size)
        #expect(icon.renderingMode == .alwaysOriginal)
        let alignment = CGRect(origin: .zero, size: icon.size).inset(by: icon.alignmentRectInsets)
        try expectBubbleCentered(
          icon, on: alignment.midX, level: dark != selected ? 255 : 0)
        #expect(abs(alignment.midY - 21) <= 1)
        if count == 0 {
          #expect(icon.pngData() == initial.pngData(), "Unknown and zero totals have no visual count.")
        } else {
          #expect(icon.pngData() != initial.pngData())
          try expectForegroundCount(icon, dark: dark)
        }
        Attachment.record(
          icon,
          named: "comments-icon-\(count)-\(dark ? "Dark" : "Light")-\(selected ? "selected" : "unselected")-\(category.rawValue).png",
          as: .png)
      }
    }
  }

  private func expectBubbleCentered(_ image: UIImage, on axis: CGFloat, level: Int) throws {
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
    let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 250 }
    #expect(!opaque.isEmpty)
    #expect(
      opaque.allSatisfy { abs(Int(pixels[$0]) - level) <= 8 },
      "The bubble must invert on the native selected fill.")
    let first = try #require(columns.min())
    let last = try #require(columns.max())
    let center = CGFloat(first + last) / (2 * image.scale)
    #expect(abs(center - axis) <= 1, "The bubble, not its count, must center on the native toolbar axis.")
  }

  private func expectForegroundCount(_ image: UIImage, dark: Bool) throws {
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
    let foreground = dark ? 255 : 0
    let inverse = 255 - foreground
    let centerRow = Int(8 * image.scale)
    let fill = (centerRow * bitmap.width + Int(34 * image.scale)) * 4
    let ring = (centerRow * bitmap.width + Int(35.5 * image.scale)) * 4
    #expect(pixels[fill + 3] > 250)
    #expect(abs(Int(pixels[fill]) - foreground) <= 8, "The count uses primary foreground fill.")
    #expect(pixels[ring + 3] > 250)
    #expect(abs(Int(pixels[ring]) - inverse) <= 8, "A background-colored ring separates selection.")
    let columns = (0..<bitmap.width).filter {
      pixels[(centerRow * bitmap.width + $0) * 4 + 3] > 250
    }
    let first = try #require(columns.first)
    let last = try #require(columns.last)
    let core = UIBezierPath(
      roundedRect: CGRect(
        x: CGFloat(first) / image.scale, y: 0,
        width: CGFloat(last - first + 1) / image.scale, height: 16).insetBy(dx: 2, dy: 2),
      cornerRadius: 6)
    let inverseText = opaque.filter { offset in
      let pixel = offset / 4
      let point = CGPoint(
        x: (CGFloat(pixel % bitmap.width) + 0.5) / image.scale,
        y: (CGFloat(pixel / bitmap.width) + 0.5) / image.scale)
      return core.contains(point) && abs(Int(pixels[offset]) - inverse) <= 8
    }
    #expect(inverseText.count >= 9, "Inverse digits must be readable inside the fill, not just its ring.")
  }
}
