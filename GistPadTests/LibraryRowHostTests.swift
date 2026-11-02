import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryRowHostTests {
  @Test(arguments: [false, true])
  func metadataUsesRenderedSecondaryInkOnSelectedAndUnselectedRows(
    dark: Bool
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 951, height: 900)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.accessibilityContrast = .normal
    window.traitOverrides.horizontalSizeClass = .regular
    window.traitOverrides.preferredContentSizeCategory = .large
    let model = LibraryModel(
      snapshot: .init(notes: ["selected", "unselected"].map { id in
        LibraryNote(id: id, title: id, updatedAt: .now, gistID: id)
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
        $0.accessibilityIdentifier == "capture-frame-note-date-unselected"
          && !$0.bounds.isEmpty
      }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(200))
    let selectedCount = descendants(window).compactMap { $0 as? UICollectionView }
      .reduce(0) { $0 + ($1.indexPathsForSelectedItems?.count ?? 0) }
    #expect(selectedCount == 1)
    let normal = try renderedSecondaryInk(in: window)
    window.traitOverrides.accessibilityContrast = .high
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let increased = try renderedSecondaryInk(in: window)
    #expect(normal.inks.count == 2)
    for key in normal.inks.keys.sorted() {
      let base = try #require(normal.inks[key])
      let high = try #require(increased.inks[key])
      for (mode, ink) in [("Normal", base), ("High", high)] {
        #expect(
          ink.count >= 8,
          "\(key) \(mode) needs solid ink, found \(ink.count) pixels on \(ink.background.hex)")
        #expect(
          ink.residual <= 6,
          "\(key) \(mode) ink \(ink.ink.hex) is off the background-to-label line by \(ink.residual)")
        #expect(
          ink.position > 0.3 && ink.position < 0.95,
          "\(key) \(mode) ink sits \(ink.position) of the way to the label color, expected muted secondary ink")
      }
      #expect(
        high.contrast > base.contrast,
        "\(key) must gain contrast at Increased Contrast, \(high.contrast):1 vs \(base.contrast):1")
      Attachment.record(
        "\(key): Normal \(base.ink.hex) on \(base.background.hex), position \(base.position), \(base.contrast):1; High \(high.ink.hex) on \(high.background.hex), position \(high.position), \(high.contrast):1",
        named: "secondary-\(dark ? "Dark" : "Light")-\(key).txt")
    }
    Attachment.record(
      normal.image, named: "secondary-\(dark ? "Dark" : "Light")-Normal.png", as: .png)
  }

  @Test(arguments: [280, 350], [DynamicTypeSize.large, .accessibility3])
  func dailyRowsStayOneLineWithTrailingProgress(
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
      tagIDs: ["ideas"], progress: .init(completed: 3, total: 4),
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
    let padding = UIFontMetrics(forTextStyle: .body).scaledValue(for: 21, compatibleWith: traits)

    #expect(abs(content.width - CGFloat(width)) <= 1)
    #expect(content.contains(title))
    #expect(content.contains(progress))
    #expect(!title.intersects(progress))
    #expect(abs(progress.maxX - content.maxX) <= 1)
    #expect(abs(title.minY - content.minY - padding) <= 1)
    #expect(abs(content.maxY - max(title.maxY, progress.maxY) - padding) <= 1)
    #expect(!descendants(window).contains {
      $0.accessibilityIdentifier == "capture-frame-note-tags-shelf-progress"
    })
    if size == .accessibility3 && width == 280 {
      #expect(progress.minY >= title.maxY)
    } else if size == .large {
      #expect(progress.midY >= title.minY && progress.midY <= title.maxY)
    }
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility3])
  func untaggedRowsKeepTheCountAndDateOnTheTitleLine(size: DynamicTypeSize) async throws {
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
      isOwned: false, isSecret: false, isStarred: true, commentCount: 3)
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
    let date = try frame("date")
    let count = try frame("comment-count")
    let padding = UIFontMetrics(forTextStyle: .body).scaledValue(for: 21, compatibleWith: traits)
    let titleFont = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
    let twoLines = UILabel()
    twoLines.font = titleFont
    twoLines.text = note.title
    twoLines.numberOfLines = 2
    twoLines.lineBreakMode = .byTruncatingTail
    let twoLineHeight = twoLines.sizeThatFits(
      CGSize(width: title.width, height: .greatestFiniteMagnitude)).height
    #expect(content.contains(title))
    #expect(content.contains(date))
    #expect(abs(date.maxX - content.maxX) <= 1)
    #expect(count.maxX <= date.minX)
    #expect(count.midY > date.minY && count.midY < date.maxY)
    #expect(abs(title.minY - content.minY - padding) <= 1)
    #expect(abs(content.maxY - max(title.maxY, date.maxY) - padding) <= 1)
    #expect(!descendants(window).contains {
      $0.accessibilityIdentifier == "capture-frame-note-tags-shelf-untagged"
    })
    if size.isAccessibilitySize {
      #expect(title.height > twoLineHeight)
      #expect(date.minY >= title.maxY)
    } else {
      #expect(title.height <= twoLineHeight + 1)
      #expect(date.midY > title.minY && date.midY < title.maxY)
      #expect(title.maxX <= count.minX)
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private struct RenderedInk {
    let background: RGBColor
    let ink: RGBColor
    let count: Int
    let position: Double
    let residual: Double

    var contrast: Double { ink.contrast(with: background) }
  }

  /// Reads the secondary ink that rendered. The ink of each date is its most common pixel
  /// that departs from the card, and it should sit on the line from that card to the label color.
  private func renderedSecondaryInk(
    in window: UIWindow
  ) throws -> (image: UIImage, inks: [String: RenderedInk]) {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let label = uiChannels(UIColor.label.resolvedColor(with: window.traitCollection))
    var inks: [String: RenderedInk] = [:]
    for id in ["selected", "unselected"] {
      let content = try frame(in: window, identifier: "capture-frame-note-content-\(id)")
      let contentPixels = try metadataPixels(in: image, rect: content)
      let background = try #require(contentPixels.max { $0.value < $1.value }?.key)
      for part in ["date"] {
        let marker = try frame(in: window, identifier: "capture-frame-note-\(part)-\(id)")
        let pixels = try metadataPixels(in: image, rect: marker.insetBy(dx: -1, dy: -1))
        let found = try #require(
          pixels.filter { distance($0.key, background) > 24 }.max { $0.value < $1.value },
          "\(id) \(part) has no ink that departs from the card")
        let backgroundChannels = channels(background)
        let delta = zip(channels(found.key), backgroundChannels).map { $0 - $1 }
        let axis = zip(label, backgroundChannels).map { $0 - $1 }
        let axisLength = axis.reduce(0) { $0 + $1 * $1 }
        let position = zip(delta, axis).reduce(0) { $0 + $1.0 * $1.1 } / axisLength
        let residual = zip(delta, axis).map { abs($0.0 - position * $0.1) }.max() ?? .infinity
        inks["\(id)-\(part)"] = RenderedInk(
          background: background, ink: found.key, count: found.value,
          position: position, residual: residual)
      }
    }
    return (image, inks)
  }

  private func frame(in window: UIWindow, identifier: String) throws -> CGRect {
    let view = try #require(descendants(window).first {
      $0.accessibilityIdentifier == identifier && !$0.bounds.isEmpty && $0.window === window
    })
    return view.convert(view.bounds, to: window)
  }

  private func distance(_ lhs: RGBColor, _ rhs: RGBColor) -> Int {
    max(
      abs(Int(lhs.red) - Int(rhs.red)), abs(Int(lhs.green) - Int(rhs.green)),
      abs(Int(lhs.blue) - Int(rhs.blue)))
  }

  private func channels(_ color: RGBColor) -> [Double] {
    [Double(color.red), Double(color.green), Double(color.blue)]
  }

  private func uiChannels(_ color: UIColor) -> [Double] {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [Double(red), Double(green), Double(blue)].map { $0 * 255 }
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
