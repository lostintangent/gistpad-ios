import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryRowHostTests {
  @Test(arguments: [false, true], [false, true])
  func metadataUsesSystemSecondaryInkOnSelectedAndUnselectedRows(
    dark: Bool, increased: Bool
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 951, height: 900)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.accessibilityContrast = increased ? .high : .normal
    window.traitOverrides.horizontalSizeClass = .regular
    window.traitOverrides.preferredContentSizeCategory = .large
    let model = LibraryModel(
      snapshot: .init(notes: ["selected", "unselected"].map { id in
        LibraryNote(
          id: id, title: id, updatedAt: .now, gistID: id,
          excerpt: "Thoughts worth keeping close.")
      }),
      loadState: .ready)
    model.selectedNoteID = "selected"
    window.rootViewController = UIHostingController(
      rootView: NavigationSplitView(columnVisibility: .constant(.all)) {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}),
          isSidebar: true)
          .navigationSplitViewColumnWidth(350)
      } detail: {
        Text("Retained document")
      }
      .librarySearch(model: model)
      .environment(\.horizontalSizeClass, .regular)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.dynamicTypeSize, .large)
      .environment(\.locale, Locale(identifier: "en_US")))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      if descendants(window).contains(where: {
        $0.accessibilityIdentifier == "capture-frame-note-excerpt-unselected"
          && !$0.bounds.isEmpty
      }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(200))
    let selectedCount = descendants(window).compactMap { $0 as? UICollectionView }
      .reduce(0) { $0 + ($1.indexPathsForSelectedItems?.count ?? 0) }
    #expect(selectedCount == 1)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    for id in ["selected", "unselected"] {
      let content = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-content-\(id)"
          && !$0.bounds.isEmpty && $0.window === window
      })
      let contentRect = content.convert(content.bounds, to: window)
      // The strip above the title holds only card or selection surface, so it is the true background.
      let surface = CGRect(
        x: contentRect.minX + 4, y: contentRect.minY + 2,
        width: contentRect.width - 8, height: 6)
      let surfacePixels = try metadataPixels(in: image, rect: surface)
      let background = try #require(surfacePixels.max { $0.value < $1.value }?.key)
      for part in ["date", "excerpt"] {
        let marker = try #require(descendants(window).first {
          $0.accessibilityIdentifier == "capture-frame-note-\(part)-\(id)"
            && !$0.bounds.isEmpty && $0.window === window
        })
        let rect = marker.convert(marker.bounds, to: window).insetBy(dx: -1, dy: -1)
        let pixels = try metadataPixels(in: image, rect: rect)
        let ink = renderedSecondaryInk(over: background, traits: window.traitCollection)
        let solidInkCount = pixels.reduce(0) { count, pixel in
          let color = pixel.key
          let matches = abs(Int(color.red) - Int(ink.red)) <= 4
            && abs(Int(color.green) - Int(ink.green)) <= 4
            && abs(Int(color.blue) - Int(ink.blue)) <= 4
          return count + (matches ? pixel.value : 0)
        }
        let dominant = pixels.sorted { $0.value > $1.value }.prefix(4)
          .map { "\($0.key.hex)x\($0.value)" }
        #expect(
          solidInkCount >= 8,
          "\(id) \(part) must render \(ink.hex) on \(background.hex); dominant colors \(dominant)")
        let ratio = ink.contrast(with: background)
        let normalInk = renderedSecondaryInk(
          over: background,
          traits: window.traitCollection.modifyingTraits { $0.accessibilityContrast = .normal })
        let normalRatio = normalInk.contrast(with: background)
        if increased {
          #expect(
            ratio > normalRatio,
            "\(id) \(part) must gain contrast at Increased Contrast, \(ratio):1 vs \(normalRatio):1")
        }
        Attachment.record(
          "\(id) \(part): \(ink.hex) on \(background.hex), \(ratio):1 (normal \(normalRatio):1), solid pixels: \(solidInkCount)",
          named: "metadata-\(id)-\(part)-\(dark)-\(increased).txt")
      }
    }
    Attachment.record(
      image, named: "metadata-\(dark ? "Dark" : "Light")-\(increased ? "High" : "Normal").png",
      as: .png)
  }

  @Test(arguments: [280, 350], [DynamicTypeSize.large, .accessibility3])
  func adaptiveRowsKeepTheirTitleProgressAndSpacing(
    width: Int, size: DynamicTypeSize
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let category: UIContentSizeCategory = size == .large ? .large : .accessibilityExtraLarge
    window.traitOverrides.preferredContentSizeCategory = category
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let day = try #require(ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z"))
    let note = LibraryNote(
      id: "shelf-progress", title: "2026-10-23", updatedAt: .now,
      isDailyNote: true, filename: "2026-10-23.md", fileCount: 3,
      excerpt: "Keep the useful thoughts close.", progress: .init(completed: 3, total: 4),
      isOverdue: true, dailyDate: day)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    window.rootViewController = UIHostingController(
      rootView: VStack {
        LibraryNoteRow(note: note, tags: Array(InterfaceFixtures.library.tags.prefix(2)))
          .frame(width: CGFloat(width))
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
      }
      .environment(\.dynamicTypeSize, size)
      .environment(\.locale, Locale(identifier: "en_US"))
      .environment(\.calendar, calendar)
      .environment(\.timeZone, .gmt))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(350))
    window.layoutIfNeeded()

    func frame(_ part: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-\(part)-shelf-progress"
          && !$0.bounds.isEmpty && !$0.isHidden && $0.window === window
      })
      return marker.convert(marker.bounds, to: window)
    }
    let content = try frame("content")
    let title = try frame("title")
    let progress = try frame("progress")
    let secondary = try frame("secondary")
    let tags = try frame("tags")
    let metrics = UIFontMetrics(forTextStyle: .body)
    let gap = metrics.scaledValue(for: 3, compatibleWith: traits)
    let tagGap = metrics.scaledValue(for: 6, compatibleWith: traits)
    let padding = metrics.scaledValue(for: 12, compatibleWith: traits)

    #expect(abs(content.width - CGFloat(width)) <= 1)
    #expect(content.contains(title))
    #expect(content.contains(progress))
    #expect(!title.intersects(progress))
    #expect(abs(progress.maxX - content.maxX) <= 1)
    #expect(abs(secondary.minY - max(title.maxY, progress.maxY) - gap) <= 1)
    #expect(abs(tags.minY - secondary.maxY - tagGap) <= 1)
    #expect(abs(title.minY - content.minY - padding) <= 1)
    #expect(abs(content.maxY - tags.maxY - padding) <= 1)
    if size == .accessibility3 && width == 280 {
      #expect(progress.minY >= title.maxY)
    } else if size == .large {
      #expect(progress.midY >= title.minY && progress.midY <= title.maxY)
    }
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility3])
  func longUntaggedRowsGrowWithoutReservingTagSpace(size: DynamicTypeSize) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let category: UIContentSizeCategory = size == .large ? .large : .accessibilityExtraLarge
    window.traitOverrides.preferredContentSizeCategory = category
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let note = LibraryNote(
      id: "shelf-untagged",
      title: "📚 A longer thought about the things we choose to keep close",
      updatedAt: .now, gistID: "shared", owner: "notebook-friend",
      isOwned: false, isSecret: false, isStarred: true,
      excerpt: "Words that stay readable when the title and date need more room.")
    window.rootViewController = UIHostingController(
      rootView: VStack {
        LibraryNoteRow(note: note, tags: [])
          .frame(width: 280)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
      }
      .environment(\.dynamicTypeSize, size)
      .environment(\.locale, Locale(identifier: "en_US")))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(350))
    window.layoutIfNeeded()
    func frame(_ part: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-\(part)-shelf-untagged"
          && !$0.bounds.isEmpty && !$0.isHidden && $0.window === window
      })
      return marker.convert(marker.bounds, to: window)
    }
    let content = try frame("content")
    let title = try frame("title")
    let secondary = try frame("secondary")
    let metrics = UIFontMetrics(forTextStyle: .body)
    let gap = metrics.scaledValue(for: 3, compatibleWith: traits)
    let padding = metrics.scaledValue(for: 12, compatibleWith: traits)
    let titleFont = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
    let twoLines = UILabel()
    twoLines.font = titleFont
    twoLines.text = note.title
    twoLines.numberOfLines = 2
    twoLines.lineBreakMode = .byTruncatingTail
    let twoLineHeight = twoLines.sizeThatFits(
      CGSize(width: title.width, height: .greatestFiniteMagnitude)).height
    #expect(content.contains(title))
    #expect(content.contains(secondary))
    #expect(abs(secondary.minY - title.maxY - gap) <= 1)
    #expect(abs(title.minY - content.minY - padding) <= 1)
    #expect(abs(content.maxY - secondary.maxY - padding) <= 1)
    #expect(!descendants(window).contains {
      $0.accessibilityIdentifier == "capture-frame-note-tags-shelf-untagged"
    })
    if size.isAccessibilitySize {
      #expect(title.height > twoLineHeight)
    } else {
      #expect(title.height <= twoLineHeight + 1)
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  /// `secondaryLabel` is translucent, so the ink that actually renders is its blend over the surface.
  private func renderedSecondaryInk(over background: RGBColor, traits: UITraitCollection) -> RGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    _ = UIColor.secondaryLabel.resolvedColor(with: traits)
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    func mix(_ ink: CGFloat, _ surface: UInt8) -> UInt8 {
      UInt8((ink * 255 * alpha + CGFloat(surface) * (1 - alpha)).rounded())
    }
    return RGBColor(
      red: mix(red, background.red), green: mix(green, background.green),
      blue: mix(blue, background.blue))
  }

  private func metadataPixels(in image: UIImage, rect: CGRect) throws -> [RGBColor: Int] {
    let source = try #require(image.cgImage?.cropping(to: CGRect(
      x: floor(rect.minX * image.scale), y: floor(rect.minY * image.scale),
      width: ceil(rect.width * image.scale), height: ceil(rect.height * image.scale))))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
    try bytes.withUnsafeMutableBytes { storage in
      let context = try #require(CGContext(
        data: storage.baseAddress, width: source.width, height: source.height,
        bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(source, in: .init(x: 0, y: 0, width: source.width, height: source.height))
    }
    return stride(from: 0, to: bytes.count, by: 4).reduce(into: [:]) { colors, index in
      let color = RGBColor(red: bytes[index], green: bytes[index + 1], blue: bytes[index + 2])
      colors[color, default: 0] += 1
    }
  }
}
