import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryHostTests {
  @Test(arguments: LibraryCollection.allCases)
  func titleMenuContainsEveryCollectionAndChecksOnlyTheCurrentCollection(
    collection: LibraryCollection
  ) async throws {
    let currentTitle = switch collection {
    case .gists: "All Notes"
    case .dailyNotes: "Daily Notes"
    case .starred: "Starred"
    case .archive: "Archive"
    }
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
    let window = UIWindow(windowScene: scene)
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.collection = collection
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let item = try #require(bar.topItem)
    #expect(item.title == (collection == .gists ? "Library" : currentTitle))
    let menu = try #require(item.titleMenuProvider?([]))
    let choices = menuActions(menu)
    let titles = Set(choices.map(\.title))
    #expect(titles.isSuperset(of: ["All Notes", "Daily Notes", "Starred", "Archive"]))
    let selected = choices.filter { $0.state == .on }
    #expect(selected.map(\.title) == [currentTitle])
  }

  @Test(arguments: [323, 324])
  func featuredCardsNeedTwoReadableColumns(usableWidth: Int) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
    let window = UIWindow(windowScene: scene)
    var frames: [Int: CGRect] = [:]
    window.rootViewController = UIHostingController(
      rootView: HStack(spacing: 0) {
        LibraryView.FeaturedGrid {
          ForEach(0..<2) { index in
            Text("Card")
              .padding(16)
              .frame(maxWidth: .infinity)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frames[index] = $0
              }
          }
        }
        .frame(width: CGFloat(usableWidth))
        Spacer(minLength: 0)
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let first = try #require(frames[0])
    let second = try #require(frames[1])
    if usableWidth == 324 {
      #expect(abs(first.minY - second.minY) < 1)
      #expect(first.width >= 156)
      #expect(second.width >= 156)
      #expect(abs(second.minX - first.maxX - 12) < 1)
    } else {
      #expect(second.minY >= first.maxY)
      #expect(first.width > 300)
    }
  }

  @Test(arguments: [280, 900], [false, true])
  func mountedSidebarAndWideLayoutsStayNative(width: Int, dark: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: width, height: 800)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let content: AnyView
    let model = LibraryModel(
      snapshot: InterfaceFixtures.library, loadState: .ready,
      today: .init(date: InterfaceFixtures.referenceDate, availability: .missing))
    if width == 280 {
      content = AnyView(
        NavigationStack {
          LibraryView(
            model: model,
            actions: .init(refresh: {}, create: {}, today: {}),
            isTodaySelected: true, isSidebar: true)
        })
    } else {
      content = AnyView(
        NavigationSplitView {
          LibraryView(
            model: model, actions: .init(refresh: {}, create: {}, today: {}),
            isTodaySelected: true, isSidebar: true)
        } detail: {
          NavigationStack {
            TodayLanding(summary: model.today) {}
          }
        }
        .librarySearch(model: model))
    }
    let host = UIHostingController(
      rootView: content
        .environment(\.horizontalSizeClass, .regular)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.colorScheme, dark ? .dark : .light))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .seconds(1))
    window.layoutIfNeeded()
    #expect(host.view.bounds.width == CGFloat(width))
    #expect(descendants(window).contains { $0 is UINavigationBar })
    print("Mounted Library container: \(host.view.bounds), native scene: \(scene.effectiveGeometry.coordinateSpace.bounds)")
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let sidebarImage = UIGraphicsImageRenderer(size: CGSize(width: 280, height: 800)).image { _ in
      image.draw(at: .zero)
    }
    let expected = PersonalAccent().roles(traits: window.traitCollection).text
    let counts = try accentPixels(in: sidebarImage, expected: expected)
    #expect(counts.personal > 30, "Today and sidebar selection must use the personal accent.")
    #expect(counts.systemBlue == 0, "The native sidebar must not retain a system-blue Today symbol.")
    Attachment.record(
      image, named: "mounted-library-\(width)-\(dark ? "Dark" : "Light")-Large.png", as: .png)
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility3])
  func ordinaryRowsKeepMetadataTogetherWithoutClipping(size: DynamicTypeSize) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let note = LibraryNote(
      id: "metadata", title: "Words worth keeping",
      updatedAt: .now.addingTimeInterval(-172_800), tagIDs: ["ideas"], fileCount: 3,
      excerpt: "A few sentences to return to when a thought needs a starting point.")
    let tags = [LibraryTag(id: "ideas", name: "Ideas", colorHex: "#EBC85A")]
    var measuredSize: CGSize?
    var metadataSize: CGSize?
    window.rootViewController = UIHostingController(
      rootView: VStack {
        LibraryView.NoteRowContent(note: note, tags: tags)
          .frame(width: 324)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
        LibraryView.NoteRowMetadata(note: note, tags: tags)
          .frame(width: 324)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { metadataSize = $0 }
        Spacer()
      }
      .environment(\.dynamicTypeSize, size))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let measured = try #require(measuredSize)
    let metadata = try #require(metadataSize)
    #expect(measured.width == 324)
    if size == .large {
      #expect(measured.height <= 128)
      #expect(metadata.height <= 30)
    } else {
      #expect(measured.height > 128)
      #expect(metadata.height > 30)
    }
  }

  @Test(arguments: [false, true])
  func collectionMenuOpensAsNativeUI(dark: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.collection = dark ? .starred : .gists
    let title = dark ? "Starred" : "Library"
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      }
      .environment(\.dynamicTypeSize, .large)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let titleButton = try #require(
      descendants(bar).compactMap { $0 as? UIControl }.first { button in
        button.accessibilityLabel?.contains(title) == true
          || descendants(button).compactMap { $0 as? UILabel }.contains { $0.text == title }
      })
    titleButton.performPrimaryAction()
    try await Task.sleep(for: .milliseconds(400))
    let visibleTitles = Set(scene.windows.filter { !$0.isHidden }.flatMap { window in
      descendants(window).compactMap { ($0 as? UILabel)?.text }
    })
    #expect(visibleTitles.isSuperset(of: ["All Notes", "Daily Notes", "Starred", "Archive"]))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      for overlay in scene.windows where !overlay.isHidden && overlay.windowLevel > window.windowLevel {
        overlay.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
    }
    Attachment.record(image, named: "collection-menu-\(dark ? "Dark" : "Light")-Large.png", as: .png)
    for interaction in titleButton.interactions.compactMap({ $0 as? UIContextMenuInteraction }) {
      interaction.dismissMenu()
    }
    window.rootViewController?.dismiss(animated: false)
    try await Task.sleep(for: .milliseconds(300))
  }

  @Test(arguments: [false, true])
  func searchOpensAsNativeUI(dark: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.query = "notebook"
    model.searchState = .results(
      notes: InterfaceFixtures.library.notes.filter { $0.id == "shape" },
      coverage: .init(totalDocuments: 7, documentsWithCachedContent: 1))
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      }
      .environment(\.dynamicTypeSize, .large)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.isHidden = true
    }
    try await Task.sleep(for: .milliseconds(400))
    let searchButton = try #require(
      descendants(window).compactMap { $0 as? UIControl }.first { $0.accessibilityLabel == "Search" })
    searchButton.performPrimaryAction()
    try await Task.sleep(for: .milliseconds(1200))
    let field = try #require(
      descendants(window).compactMap { $0 as? UITextField }.first {
        $0.window != nil && $0.text == "notebook"
      })
    #expect(field.isFirstResponder)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      for overlay in scene.windows where !overlay.isHidden && overlay.windowLevel > window.windowLevel {
        overlay.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
    }
    Attachment.record(image, named: "library-search-\(dark ? "Dark" : "Light")-Large.png", as: .png)
  }

  @Test(arguments: [false, true], [nil, "#FACC15"] as [String?])
  func searchAndEmptyControlsUsePersonalAccent(dark: Bool, savedHex: String?) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    let model = LibraryModel(snapshot: InterfaceFixtures.library, loadState: .ready)
    model.query = "No matching words"
    model.selectedTagIDs = ["ideas"]
    model.searchState = .results(
      notes: [], coverage: .init(totalDocuments: 8, documentsWithCachedContent: 2))
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      }
      .librarySearch(model: model)
      .personalAccent(savedHex: savedHex)
      .environment(\.dynamicTypeSize, .large)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let expected = PersonalAccent(savedHex: savedHex).roles(traits: window.traitCollection).text
    let counts = try accentPixels(in: image, expected: expected)
    #expect(counts.personal > 30, "The scope and Clear actions must render the account accent.")
    #expect(counts.systemBlue == 0, "Library content must not fall back to system-blue controls.")
    Attachment.record(
      image, named: "search-accent-\(savedHex ?? "Sky")-\(dark ? "Dark" : "Light").png", as: .png)
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility3], [2, 8])
  func searchCoverageIsOneUnboxedCaption(size: DynamicTypeSize, cachedCount: Int) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    var measuredSize: CGSize?
    window.rootViewController = UIHostingController(
      rootView: VStack {
        LibraryView.SearchSummary(
          coverage: .init(totalDocuments: 8, documentsWithCachedContent: cachedCount), selectedTagCount: 0)
          .frame(width: 324, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
        Spacer()
      }
      .environment(\.dynamicTypeSize, size))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    let measured = try #require(measuredSize)
    #expect(measured.width == 324)
    if size == .large {
      #expect(measured.height <= 66)
    } else {
      #expect(measured.height > 66)
    }
  }

  private func accentPixels(in image: UIImage, expected: RGBColor) throws
    -> (personal: Int, systemBlue: Int)
  {
    let source = try #require(image.cgImage)
    let width = source.width
    let height = source.height
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(
        CGContext(
          data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: pixels.count, by: 4).reduce(into: (0, 0)) { counts, index in
      let red = Int(pixels[index])
      let green = Int(pixels[index + 1])
      let blue = Int(pixels[index + 2])
      if abs(red - Int(expected.red)) <= 6, abs(green - Int(expected.green)) <= 6,
        abs(blue - Int(expected.blue)) <= 6, pixels[index + 3] > 250
      {
        counts.0 += 1
      }
      if red < 30, green > 90, green < 160, blue > 245, pixels[index + 3] > 250 {
        counts.1 += 1
      }
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func menuActions(_ menu: UIMenu) -> [UIAction] {
    menu.children.flatMap { child in
      if let menu = child as? UIMenu { return menuActions(menu) }
      return (child as? UIAction).map { [$0] } ?? []
    }
  }

}
