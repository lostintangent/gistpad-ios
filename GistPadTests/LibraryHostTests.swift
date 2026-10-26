import GistPadAppearance
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryHostTests {
  @Test(arguments: LibraryCollection.allCases)
  func homeKeepsItsMainTotalAndHasNoCollectionTitleMenu(
    collection: LibraryCollection
  ) async throws {
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
    #expect(item.title == "GistPad")
    #expect(item.subtitle == "4 gists")
    #expect(item.titleMenuProvider?([]) == nil)
  }

  @Test(arguments: [LibraryCollection.dailyNotes, .starred, .archive])
  func aSelectedSecondaryDocumentUsesItsRealNativeRow(collection: LibraryCollection) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 900, height: 800)
    let target = LibraryNote(
      id: "secondary", title: "A selected thought", updatedAt: InterfaceFixtures.referenceDate,
      gistID: "secondary", isOwned: collection != .starred,
      isStarred: collection == .starred, isArchived: collection == .archive,
      isDailyNote: collection == .dailyNotes)
    let model = LibraryModel(
      snapshot: .init(
        notes: [
          .init(
            id: "main", title: "A pinned thought", updatedAt: InterfaceFixtures.referenceDate,
            gistID: "main", isPinned: true),
          target
        ],
        dailyNoteCount: collection == .dailyNotes ? 1 : 0),
      loadState: .ready)
    model.selectedNoteID = target.id
    window.rootViewController = UIHostingController(
      rootView: NavigationSplitView {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}),
          isSidebar: true, expandedCollections: .constant([collection]))
      } detail: {
        Text("The retained document")
      }
      .environment(\.horizontalSizeClass, .regular))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let list = try #require(descendants(window).compactMap { $0 as? UICollectionView }.first)
    let selected = try #require(list.indexPathsForSelectedItems)
    #expect(selected.count == 1)
    let cell = try #require(selected.first.flatMap { list.cellForItem(at: $0) })
    #expect(descendants(cell).contains {
      $0.accessibilityIdentifier == "capture-frame-note-title-secondary"
    })
    #expect(model.selectedNoteID == target.id)
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
            Color(uiColor: .systemBackground)
              .navigationTitle("Today")
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
  func ordinaryRowsKeepTagsBelowTheDateAndExcerptWithoutClipping(size: DynamicTypeSize) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.traitOverrides.preferredContentSizeCategory =
      size == .large ? .large : .accessibilityExtraLarge
    let note = LibraryNote(
      id: "metadata", title: "Words worth keeping",
      updatedAt: .now.addingTimeInterval(-172_800), tagIDs: ["ideas"], fileCount: 3,
      excerpt: "A few sentences to return to when a thought needs a starting point.")
    let tags = [LibraryTag(id: "ideas", name: "Ideas", colorHex: "#EBC85A")]
    var measuredSize: CGSize?
    window.rootViewController = UIHostingController(
      rootView: VStack {
        LibraryNoteRow(note: note, tags: tags)
          .frame(width: 324)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSize = $0 }
        Spacer()
      }
      .environment(\.dynamicTypeSize, size))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let measured = try #require(measuredSize)
    let marker = try #require(descendants(window).first {
      $0.accessibilityIdentifier == "capture-frame-note-tags-metadata" && !$0.bounds.isEmpty
    })
    let metadata = marker.bounds.size
    #expect(measured.width == 324)
    if size == .large {
      #expect(measured.height <= 128)
      #expect(metadata.height <= 30)
    } else {
      #expect(measured.height > 128)
      #expect(metadata.height > 30)
    }
  }

  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func pinnedCardsKeepAReal28PointTransitionBeforeOrdinaryRows(
    isSidebar: Bool, size: DynamicTypeSize
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: isSidebar ? 900 : 466, height: 800)
    window.traitOverrides.preferredContentSizeCategory =
      size.isAccessibilitySize ? .accessibilityExtraLarge : .large
    let model = LibraryModel(
      snapshot: .init(notes: [
        .init(id: "pin", title: "One good thought", updatedAt: .now, gistID: "pin", isPinned: true),
        .init(id: "ordinary", title: "Another thought", updatedAt: .now, gistID: "ordinary"),
      ]), loadState: .ready)
    let library = LibraryView(
      model: model, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: isSidebar)
    let content: AnyView
    if isSidebar {
      content = AnyView(NavigationSplitView { library } detail: { Text("A retained document") })
    } else {
      content = AnyView(NavigationStack { library })
    }
    window.rootViewController = UIHostingController(
      rootView: content
        .environment(\.horizontalSizeClass, isSidebar ? .regular : .compact)
        .environment(\.dynamicTypeSize, size))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    func frame(_ id: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-content-\(id)" && !$0.bounds.isEmpty
      })
      return marker.convert(marker.bounds, to: window)
    }
    let cardContent = try frame("pin")
    let ordinary = try frame("ordinary")
    let gap = ordinary.minY - (cardContent.maxY + 14)
    #expect(abs(gap - 28) <= 1, "Measured card-to-row transition: \(gap) pt")
  }

  @Test(arguments: [
    (dark: false, size: DynamicTypeSize.large, hasTags: false),
    (dark: false, size: DynamicTypeSize.large, hasTags: true),
    (dark: true, size: DynamicTypeSize.large, hasTags: false),
    (dark: true, size: DynamicTypeSize.large, hasTags: true),
    (dark: false, size: DynamicTypeSize.accessibility3, hasTags: false),
    (dark: false, size: DynamicTypeSize.accessibility3, hasTags: true),
    (dark: true, size: DynamicTypeSize.accessibility3, hasTags: false),
    (dark: true, size: DynamicTypeSize.accessibility3, hasTags: true),
  ])
  func pinnedCardsGrowWithTheirContentAndKeepMetadataBelowTheTitle(
    dark: Bool, size: DynamicTypeSize, hasTags: Bool
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.preferredContentSizeCategory =
      size == .large ? .large : .accessibilityExtraLarge
    let note = LibraryNote(
      id: "card", title: "A quiet place for the next good thought", updatedAt: .now,
      gistID: "card", isPinned: true, tagIDs: ["ideas"],
      excerpt: "Keep a thought worth coming back to.",
      progress: .init(completed: 2, total: 5), commentCount: 3)
    let simple = LibraryNote(
      id: "simple", title: "One thought", updatedAt: .now, gistID: "simple", isPinned: true)
    var cardSize: CGSize?
    var simpleSize: CGSize?
    window.rootViewController = UIHostingController(
      rootView: VStack(spacing: 8) {
        LibraryPinnedCard(
          note: note, tags: hasTags ? [
            .init(id: "ideas", name: "Ideas", colorHex: "#EBC85A"),
            .init(id: "long", name: "A complete and deliberately long tag name"),
            .init(id: "more", name: "More"),
          ] : [], isSelected: false)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
        LibraryPinnedCard(note: simple, tags: [], isSelected: false)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { simpleSize = $0 }
        Spacer(minLength: 0)
      }
      .frame(width: 280)
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light)
      .background(Color(uiColor: .systemGroupedBackground)))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let measuredCard = try #require(cardSize)
    let measuredSimple = try #require(simpleSize)
    #expect(measuredCard.width == 280)
    #expect(measuredSimple.width == measuredCard.width)
    #expect(measuredCard.height > measuredSimple.height)
    func frame(_ id: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-\(id)" && !$0.bounds.isEmpty
          && !$0.isHidden && $0.convert($0.bounds, to: window).intersects(window.bounds)
      })
      return marker.convert(marker.bounds, to: window)
    }
    let title = try frame("note-title-card")
    let excerpt = try frame("note-excerpt-card")
    let footer = try frame("note-footer-card")
    let progress = try frame("note-progress-card")
    let comments = try frame("note-comment-count-card")
    #expect(excerpt.minY >= title.maxY)
    #expect(footer.minY >= excerpt.maxY)
    if hasTags {
      let tags = try frame("note-tags-card")
      #expect(tags.minY >= excerpt.maxY)
      #expect(abs(progress.midY - tags.midY) <= 1)
      #expect(abs(comments.midY - tags.midY) <= 1)
      #expect(progress.minX >= tags.maxX + 12)
    }
    #expect(progress.maxY <= footer.maxY)
    #expect(comments.maxY <= footer.maxY)
    #expect(abs(comments.maxX - footer.maxX) <= 1)
    #expect(!descendants(window).contains {
      $0.accessibilityIdentifier == "capture-frame-note-date-card"
    })
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image, named: "pinned-card-\(dark ? "Dark" : "Light")-\(size)-tags-\(hasTags).png", as: .png)
  }

  @Test(arguments: [false, true])
  func nativeSearchFieldKeepsFocusAndSystemTextTint(dark: Bool) async throws {
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
      rootView: NavigationSplitView {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: true)
      } detail: {
        Text("The retained document")
      }
      .librarySearch(model: model, isPresented: .constant(true), isSidebar: true)
      .environment(\.horizontalSizeClass, .regular)
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
      $0.window === window && $0.text == "notebook"
    }), .now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
    }
    let field = try #require(
      descendants(window).compactMap { $0 as? UITextField }.first {
        $0.window === window && $0.text == "notebook"
      })
    #expect(field.becomeFirstResponder())
    try await Task.sleep(for: .milliseconds(350))
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      for overlay in scene.windows where !overlay.isHidden && overlay.windowLevel > window.windowLevel {
        overlay.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
    }
    Attachment.record(image, named: "library-search-\(dark ? "Dark" : "Light")-Large.png", as: .png)
    Attachment.record(
      "Key window: \(window.isKeyWindow), scene: \(scene.activationState.rawValue)\n"
        + descendants(window).compactMap { $0 as? UITextField }.map {
          "\(type(of: $0)): \($0.text ?? ""), focused: \($0.isFirstResponder), owned: \($0.window === window)"
        }.joined(separator: "\n"),
      named: "library-search-fields.txt")
    #expect(field.isFirstResponder)
    #expect(field.tintColor.resolvedColor(with: field.traitCollection)
      .isEqual(UIColor.systemBlue.resolvedColor(with: field.traitCollection)))
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

}
