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
    #expect(item.title == (collection == .gists ? "GistPad" : currentTitle))
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
    let expected = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
    let counts = try nativeAccentPixels(in: sidebarImage, expected: expected)
    #expect(counts.personal > 30, "The sidebar keeps readable native primary ink.")
    #expect(counts.systemBlue == 0, "The native sidebar selection and Today symbol stay neutral.")
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
    let title = dark ? "Starred" : "GistPad"
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
    let previous = scene.windows.first(where: \.isKeyWindow)
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
      .librarySearch(model: model, isPresented: .constant(true))
      .environment(\.dynamicTypeSize, .large)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while !descendants(window).compactMap({ $0 as? UITextField }).contains(where: {
      $0.window === window && $0.text == "notebook" && $0.isFirstResponder
    }), .now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
    }
    let field = try #require(
      descendants(window).compactMap { $0 as? UITextField }.first {
        $0.window != nil && $0.text == "notebook"
      })
    #expect(field.isFirstResponder)
    #expect(field.tintColor.resolvedColor(with: field.traitCollection)
      .isEqual(UIColor.systemBlue.resolvedColor(with: field.traitCollection)))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      for overlay in scene.windows where !overlay.isHidden && overlay.windowLevel > window.windowLevel {
        overlay.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
    }
    Attachment.record(image, named: "library-search-\(dark ? "Dark" : "Light")-Large.png", as: .png)
  }

  @Test(arguments: [false, true], [nil, "#FACC15"] as [String?])
  func searchAndEmptyControlsStayNeutral(dark: Bool, savedHex: String?) async throws {
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
    let expected = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
    let counts = try nativeAccentPixels(in: image, expected: expected)
    #expect(counts.personal > 30, "The scope and Clear actions retain readable neutral ink.")
    #expect(counts.systemBlue == 0, "Library commands must not inherit the system text-entry tint.")
    let accent = PersonalAccent(savedHex: savedHex).roles(traits: window.traitCollection).text
    #expect(try nativeAccentPixels(in: image, expected: accent).personal < 20)
    Attachment.record(
      image, named: "search-accent-\(savedHex ?? "Sky")-\(dark ? "Dark" : "Light").png", as: .png)
  }

  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func tagFilterNamesChecksAndDoneStayNeutral(dark: Bool, size: DynamicTypeSize) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.preferredContentSizeCategory =
      size.isAccessibilitySize ? .accessibilityExtraLarge : .large
    let model = LibraryModel(
      snapshot: .init(
        notes: [],
        tags: [
          .init(id: "ideas", name: "Ideas", colorHex: "#7C3AED"),
          .init(id: "work", name: "Work", colorHex: "#E93D82")
        ]), loadState: .ready)
    model.selectedTagIDs = ["ideas"]
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
          .captureTagFilters(true)
      }
      .tint(Color(uiColor: .systemGreen))
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while window.rootViewController?.presentedViewController?.view.window == nil,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(350))
    let canvas = try #require(window.rootViewController?.presentedViewController?.view)
    canvas.layoutIfNeeded()
    #expect(descendants(canvas).compactMap { $0 as? UINavigationBar }.last?.topItem?.title == "Filter by tags")
    let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { _ in
      canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true)
    }
    let label = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: canvas.traitCollection)))
    let inheritedTint = try #require(RGBColor(
      uiColor: UIColor.systemGreen.resolvedColor(with: canvas.traitCollection)))
    for id in ["library-tag-filter-ideas", "library-tag-filter-work", "library-tag-filter-done"] {
      let view = try #require(descendants(canvas).first {
        $0.accessibilityIdentifier == "capture-frame-\(id)"
      })
      let frame = view.convert(view.bounds, to: canvas).intersection(canvas.bounds)
      #expect(!frame.isEmpty)
      #expect(frame.height >= 44)
      let pixels = CGRect(
        x: frame.minX * image.scale, y: frame.minY * image.scale,
        width: frame.width * image.scale, height: frame.height * image.scale)
      let crop = try #require(image.cgImage?.cropping(to: pixels))
      let sample = UIImage(cgImage: crop)
      #expect(try nativeAccentPixels(in: sample, expected: label).personal > 20)
      #expect(try nativeAccentPixels(in: sample, expected: inheritedTint).personal < 10)
    }
    #expect(model.selectedTagIDs == ["ideas"])
    Attachment.record(
      image, named: "tag-filters-\(dark ? "Dark" : "Light")-\(size.isAccessibilitySize ? "AX3" : "Large").png",
      as: .png)
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

  @Test(arguments: [false, true], [false, true])
  func searchCoverageRetainsSemanticSecondaryColor(dark: Bool, increasedContrast: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.accessibilityContrast = increasedContrast ? .high : .normal
    window.rootViewController = UIHostingController(
      rootView: ZStack {
        Color(uiColor: .systemGroupedBackground)
        VStack {
          LibraryView.SearchSummary(
            coverage: .init(totalDocuments: 8, documentsWithCachedContent: 2), selectedTagCount: 0)
            .frame(width: 324, alignment: .leading)
          Spacer()
        }
        .padding(20)
        .foregroundStyle(.secondary)
      }
      .environment(\.dynamicTypeSize, .large)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let background = try #require(
      RGBColor(uiColor: UIColor.systemGroupedBackground.resolvedColor(with: window.traitCollection)))
    let label = UIColor.secondaryLabel.resolvedColor(with: window.traitCollection)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    try #require(label.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    let expected = RGBColor(
      red: UInt8((red * alpha * 255 + CGFloat(background.red) * (1 - alpha)).rounded()),
      green: UInt8((green * alpha * 255 + CGFloat(background.green) * (1 - alpha)).rounded()),
      blue: UInt8((blue * alpha * 255 + CGFloat(background.blue) * (1 - alpha)).rounded()))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let pixels = try nativeAccentPixels(in: image, expected: expected)
    #expect(pixels.personal > 30, "Section-header styling must not dim the semantic caption again.")
    Attachment.record(
      image, named: "coverage-secondary-\(dark ? "Dark" : "Light")-\(increasedContrast ? "High" : "Normal").png",
      as: .png)
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
