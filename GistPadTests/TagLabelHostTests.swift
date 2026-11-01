import GistPadAppearance
import GistPadInterface
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct TagLabelHostTests {
  struct Configuration: Sendable {
    let increasedContrast: Bool
    let size: DynamicTypeSize
  }

  @Test(
    arguments: [false, true], [
      Configuration(increasedContrast: false, size: .large),
      Configuration(increasedContrast: true, size: .large),
      Configuration(increasedContrast: false, size: .accessibility3),
      Configuration(increasedContrast: true, size: .accessibility3)
    ])
  func pillsUseExactFillWithBlackOrWhiteInk(
    dark: Bool, configuration: Configuration
  ) async throws {
    let increasedContrast = configuration.increasedContrast
    let size = configuration.size
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.accessibilityContrast = increasedContrast ? .high : .normal
    window.traitOverrides.preferredContentSizeCategory =
      size.isAccessibilitySize ? .accessibilityExtraLarge : .large
    let tags: [LibraryTag] = [
      .init(id: "yellow", name: "Yellow", colorHex: "#FFFF00"),
      .init(id: "white", name: "White", colorHex: "#FFFFFF"),
      .init(id: "black", name: "Black", colorHex: "#000000"),
      .init(id: "garden", name: "Garden", colorHex: "#548C80"),
      .init(id: "mint", name: "Mint", colorHex: "#588E82"),
      .init(id: "none", name: "None")
    ]
    var pillFrames: [String: CGRect] = [:]
    var textWidths: [String: CGFloat] = [:]
    window.rootViewController = UIHostingController(
      rootView: VStack(alignment: .leading, spacing: 16) {
        ForEach(tags) { tag in
          HStack(spacing: 16) {
            TagLabel(tag: tag)
              .fixedSize()
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                pillFrames[tag.id] = $0
              }
            Text(verbatim: tag.name)
              .font(.footnote.weight(.medium))
              .fixedSize()
              .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                textWidths[tag.id] = $0
              }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color(uiColor: .systemBackground))
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(350))
    window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let label = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
    for tag in tags {
      let frame = try #require(pillFrames[tag.id])
      let textWidth = try #require(textWidths[tag.id])
      #expect(abs(frame.width - textWidth - 16) <= 1, "A metadata pill has no inner color dot.")
      #expect(window.bounds.contains(frame))
      let fill = try sampledColor(
        at: CGPoint(x: frame.midX, y: frame.minY + 2), in: image)
      if let hex = tag.colorHex, let saved = RGBColor(hex: hex) {
        #expect(
          channelsMatch(fill, saved),
          "\(tag.id): saved \(saved.hex) rendered as \(fill.hex)")
        #expect(
          max(saved.contrast(with: .black), saved.contrast(with: .white)) >= 4.5,
          "\(tag.id): neither black nor white reaches 4.5:1 on \(saved.hex)")
      } else {
        #expect(
          label.contrast(with: fill) >= 4.5,
          "\(tag.id): \(label.hex) on \(fill.hex)")
      }
    }
    Attachment.record(
      image, named: "exact-fill-tags-\(dark ? "Dark" : "Light")-\(increasedContrast ? "High" : "Normal")-\(size.isAccessibilitySize ? "AX3" : "Large").png",
      as: .png)
  }

  private func channelsMatch(_ rendered: RGBColor, _ saved: RGBColor) -> Bool {
    let tolerance = 6
    return abs(Int(rendered.red) - Int(saved.red)) <= tolerance
      && abs(Int(rendered.green) - Int(saved.green)) <= tolerance
      && abs(Int(rendered.blue) - Int(saved.blue)) <= tolerance
  }

  private func sampledColor(at point: CGPoint, in image: UIImage) throws -> RGBColor {
    let source = try #require(image.cgImage)
    let crop = try #require(source.cropping(to: CGRect(
      x: floor(point.x * image.scale), y: floor(point.y * image.scale), width: 1, height: 1)))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: space,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    #expect(pixel[3] == 255)
    return RGBColor(red: pixel[0], green: pixel[1], blue: pixel[2])
  }
}
