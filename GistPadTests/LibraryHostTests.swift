import GistPadAppearance
import SwiftUI
import Testing
import UIKit
import Vision

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

  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func collectionHeadersDrawTheirFullTitlesAndBareCounts(
    dark: Bool, size: DynamicTypeSize
  ) async throws {
    #expect(LibraryCollection.dailyNotes.title == "Daily Notes")
    #expect(LibraryCollection.starred.title == "Starred Gists")
    #expect(LibraryCollection.archive.title == "Archived Gists")
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 900, height: 800)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.preferredContentSizeCategory =
      size == .large ? .large : .accessibilityExtraLarge
    let model = LibraryModel(
      snapshot: .init(notes: [
        .init(
          id: "ordinary", title: "A quiet thought", updatedAt: InterfaceFixtures.referenceDate,
          gistID: "ordinary"),
        .init(
          id: "daily", title: "A daily thought", updatedAt: InterfaceFixtures.referenceDate,
          gistID: "daily", isDailyNote: true),
        .init(
          id: "starred", title: "A starred thought", updatedAt: InterfaceFixtures.referenceDate,
          gistID: "starred", isOwned: false, isStarred: true),
        .init(
          id: "archived", title: "An archived thought", updatedAt: InterfaceFixtures.referenceDate,
          gistID: "archived", isArchived: true),
      ], dailyNoteCount: 1),
      loadState: .ready)
    window.rootViewController = UIHostingController(
      rootView: NavigationSplitView {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}),
          isSidebar: true, expandedCollections: .constant([]))
      } detail: {
        Text("The retained document")
      }
      .environment(\.horizontalSizeClass, .regular)
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let bitmap = try #require(image.cgImage)
    var headerFrames: [CGRect] = []
    var firstContentFrame: CGRect?
    for collection in [LibraryCollection.dailyNotes, .starred, .archive] {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)"
          && !$0.bounds.isEmpty
      })
      let frame = marker.convert(marker.bounds, to: window)
      #expect(window.bounds.contains(frame))
      var parent = marker.superview
      while parent != nil && !(parent is UICollectionViewCell) { parent = parent?.superview }
      let cell = try #require(parent as? UICollectionViewCell)
      let cellFrame = cell.convert(cell.bounds, to: window)
      headerFrames.append(cellFrame)
      if firstContentFrame == nil { firstContentFrame = frame }
      let count = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-count-\(collection.rawValue)"
          && !$0.bounds.isEmpty
      })
      let title = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-title-\(collection.rawValue)"
          && !$0.bounds.isEmpty
      })
      let titleFrame = title.convert(title.bounds, to: window)
      if size == .large {
        #expect(abs(cellFrame.height - 44) <= 1 / image.scale)
      } else {
        #expect(count.convert(count.bounds, to: window).minX >= titleFrame.maxX)
      }
      let crop = try #require(bitmap.cropping(to: CGRect(
        x: titleFrame.minX * image.scale, y: titleFrame.minY * image.scale,
        width: titleFrame.width * image.scale, height: titleFrame.height * image.scale)))
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: crop).perform([request])
      let words = (request.results ?? []).compactMap {
        $0.topCandidates(1).first?.string
      }.joined(separator: " ").lowercased()
      #expect(words.contains(collection.title.lowercased()), "Rendered header: \(words)")
      let countFrame = count.convert(count.bounds, to: window)
      let countCrop = try #require(bitmap.cropping(to: CGRect(
        x: countFrame.minX * image.scale, y: countFrame.minY * image.scale,
        width: countFrame.width * image.scale, height: countFrame.height * image.scale)))
      #expect(countFrame.width < countFrame.height, "The count contains only the bare digit.")
      let background = try color(in: countCrop, at: .zero)
      let backgroundPixels = try nativeAccentPixels(
        in: UIImage(cgImage: countCrop), expected: background).personal
      #expect(countCrop.width * countCrop.height - backgroundPixels > 10, "The number draws real ink.")
      let ink = try #require(RGBColor(
        uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
      #expect(ink.contrast(with: background) >= 4.5)
      #expect(try nativeAccentPixels(in: UIImage(cgImage: countCrop), expected: ink).personal > 10)
    }
    if size == .large {
      for index in 1..<headerFrames.count {
        #expect(abs(headerFrames[index].minY - headerFrames[index - 1].minY - 44) <= 1 / image.scale)
      }
    }
    let ordinary = try #require(descendants(window).first {
      $0.accessibilityIdentifier == "capture-frame-note-title-ordinary"
    })
    var parent = ordinary.superview
    while parent != nil && !(parent is UICollectionViewCell) { parent = parent?.superview }
    let cell = try #require(parent as? UICollectionViewCell)
    let ordinaryFrame = cell.convert(cell.bounds, to: window)
    #expect(abs(ordinaryFrame.height - (size == .large ? 63 : 195)) <= 1 / image.scale)
    let firstHeader = try #require(firstContentFrame)
    #expect(abs(firstHeader.minY - ordinaryFrame.maxY - 28) <= 1)
    Attachment.record(
      "Headers: \(headerFrames)\nOrdinary cell: \(ordinaryFrame)\nFirst content: \(firstHeader)",
      named: "collection-native-rhythm-\(dark)-\(size).txt")
    Attachment.record(
      image, named: "collection-titles-\(dark ? "Dark" : "Light")-\(size).png", as: .png)
  }

  @Test(arguments: [LibraryCollection.dailyNotes, .starred, .archive])
  func anExpandedHomeDisclosureDisappearsWhenEmptyWithoutClosingItsDocument(
    collection: LibraryCollection
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let note = LibraryNote(
      id: "retained", title: "Keep this document open", updatedAt: .distantPast,
      gistID: "retained", isOwned: collection != .starred,
      isStarred: collection == .starred, isArchived: collection == .archive,
      isDailyNote: collection == .dailyNotes)
    let populated = LibrarySnapshot(notes: [note], dailyNoteCount: 1)
    let model = LibraryModel(snapshot: populated, loadState: .ready)
    model.selectedNoteID = note.id
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}),
          isSidebar: true, expandedCollections: .constant([collection]))
      })
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    func headerExists() -> Bool {
      guard let list = descendants(window).compactMap({ $0 as? UICollectionView }).first else {
        return false
      }
      return list.indexPathsForVisibleItems.contains { index in
        guard let cell = list.cellForItem(at: index) else { return false }
        return descendants(cell).contains {
          $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)"
            && !$0.bounds.isEmpty
        }
      }
    }
    var deadline = ContinuousClock.now + .seconds(3)
    while !headerExists(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
    }
    #expect(headerExists())
    model.replaceSnapshot(.init(notes: [], dailyNoteCount: 0))
    deadline = ContinuousClock.now + .seconds(3)
    while headerExists(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
    }
    #expect(!headerExists())
    #expect(model.selectedNoteID == note.id)
    model.replaceSnapshot(populated)
    deadline = ContinuousClock.now + .seconds(3)
    while !headerExists(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      window.layoutIfNeeded()
    }
    #expect(headerExists())
    #expect(descendants(window).contains {
      $0.accessibilityIdentifier == "capture-frame-note-title-retained"
        && !$0.bounds.isEmpty
    })
    #expect(model.selectedNoteID == note.id)
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
        $0.accessibilityIdentifier == "capture-frame-\(id)" && !$0.bounds.isEmpty
      })
      return marker.convert(marker.bounds, to: window)
    }
    let card = try frame("note-card-pin")
    let ordinary = try frame("note-content-ordinary")
    let gap = ordinary.minY - card.maxY
    #expect(abs(gap - 28) <= 1, "Measured card-to-row transition: \(gap) pt")
  }

  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func pinnedGridKeepsAnOddCardLeadingAndUsesOneNativeListRow(
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
      snapshot: .init(notes: ["One", "Two", "Three"].map {
        .init(
          id: $0, title: $0, updatedAt: .now, gistID: $0, isPinned: true,
          excerpt: "An excerpt that never appears in the gallery")
      }), loadState: .ready)
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
    func marker(_ name: String) throws -> UIView {
      try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-\(name)" && !$0.bounds.isEmpty
      })
    }
    func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
    let grid = try frame(marker("library-pinned-grid"))
    let cards = try ["One", "Two", "Three"].map { try marker("note-card-\($0)") }
    let frames = cards.map(frame)
    let tolerance = 1 / window.traitCollection.displayScale + 0.01
    #expect(abs(frames[0].minX - grid.minX) <= tolerance)
    for (index, card) in cards.enumerated() {
      var parent = card.superview
      while parent != nil && !(parent is UICollectionViewCell) { parent = parent?.superview }
      let cell = try #require(parent as? UICollectionViewCell)
      #expect(cards.allSatisfy { $0.isDescendant(of: cell) })
      if size.isAccessibilitySize {
        #expect(abs(frames[index].width - grid.width) <= tolerance)
        if index > 0 {
          #expect(abs(frames[index].minY - frames[index - 1].maxY - 12) <= tolerance)
        }
      } else {
        #expect(abs(frames[index].height - frames[index].width) <= tolerance)
        #expect(abs(frames[index].width * 2 + 12 - grid.width) <= tolerance)
      }
    }
    if !size.isAccessibilitySize {
      #expect(abs(frames[1].minY - frames[0].minY) <= tolerance)
      #expect(abs(frames[1].minX - frames[0].maxX - 12) <= tolerance)
      #expect(abs(frames[2].minX - frames[0].minX) <= tolerance)
      #expect(abs(frames[2].minY - frames[0].maxY - 12) <= tolerance)
    }
    Attachment.record("Grid: \(grid)\nCards: \(frames)", named: "pinned-grid-\(isSidebar)-\(size)")
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
  func pinnedCardsAreSquareWithoutExcerptsAndGrowOnlyForAccessibility(
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
    let width: CGFloat = size.isAccessibilitySize ? 280 : 134
    var cardSize: CGSize?
    var simpleSize: CGSize?
    var titleLineHeight: CGFloat?
    var minimumTagNameWidth: CGFloat?
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
      .frame(width: width)
      .overlay {
        VStack {
          Text(verbatim: "Ag").font(.headline).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleLineHeight = $0 }
          Text(verbatim: "Ide…").font(.footnote.weight(.medium)).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { minimumTagNameWidth = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
      }
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light)
      .background(Color(uiColor: .systemGroupedBackground)))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(400))
    window.layoutIfNeeded()
    let measuredCard = try #require(cardSize)
    let measuredSimple = try #require(simpleSize)
    let pixelTolerance = 1 / window.traitCollection.displayScale + 0.01
    #expect(abs(measuredCard.width - width) <= pixelTolerance)
    #expect(abs(measuredSimple.width - measuredCard.width) <= pixelTolerance)
    if size.isAccessibilitySize {
      #expect(measuredCard.height > measuredSimple.height)
    } else {
      #expect(abs(measuredCard.height - width) <= pixelTolerance)
      #expect(abs(measuredSimple.height - width) <= pixelTolerance)
    }
    func frame(_ id: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-\(id)" && !$0.bounds.isEmpty
          && !$0.isHidden && $0.convert($0.bounds, to: window).intersects(window.bounds)
      })
      return marker.convert(marker.bounds, to: window)
    }
    let card = try frame("note-card-card")
    let title = try frame("note-title-card")
    let pin = try frame("note-pin-card")
    let footer = try frame("note-footer-card")
    let progress = try frame("note-progress-card")
    let comments = try frame("note-comment-count-card")
    let content = card.insetBy(dx: 12, dy: 12)
    #expect(content.insetBy(dx: -pixelTolerance, dy: -pixelTolerance).contains(title))
    #expect(content.insetBy(dx: -pixelTolerance, dy: -pixelTolerance).contains(footer))
    #expect(abs(pin.maxX - content.maxX) <= pixelTolerance)
    #expect(footer.minY >= title.maxY + 8 - pixelTolerance)
    if !size.isAccessibilitySize {
      #expect(title.height <= (try #require(titleLineHeight)) * (hasTags ? 2 : 3) + pixelTolerance)
      #expect(abs(footer.maxY - content.maxY) <= pixelTolerance)
    }
    if hasTags {
      let tags = try frame("note-tags-card")
      #expect(tags.minY >= title.maxY + 8 - pixelTolerance)
      #expect(progress.minY >= tags.maxY + 4 - pixelTolerance)
      #expect(abs(progress.midY - comments.midY) <= 1)
      if let name = descendants(window).first(where: {
        $0.accessibilityIdentifier == "capture-frame-pinned-tag-summary-name"
          && !$0.bounds.isEmpty
      }) {
        #expect(name.bounds.width >= (try #require(minimumTagNameWidth)) - pixelTolerance)
      }
    }
    #expect(progress.maxY <= footer.maxY)
    #expect(comments.maxY <= footer.maxY)
    #expect(abs(comments.maxX - footer.maxX) <= 1)
    for part in ["date", "excerpt"] {
      #expect(!descendants(window).contains {
        $0.accessibilityIdentifier == "capture-frame-note-\(part)-card"
      })
    }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image, named: "pinned-card-\(dark ? "Dark" : "Light")-\(size)-tags-\(hasTags).png", as: .png)
  }

  @Test(arguments: [
    (dark: false, size: DynamicTypeSize.large, increasedContrast: false),
    (dark: true, size: DynamicTypeSize.large, increasedContrast: false),
    (dark: false, size: DynamicTypeSize.accessibility3, increasedContrast: false),
    (dark: true, size: DynamicTypeSize.accessibility3, increasedContrast: false),
    (dark: false, size: DynamicTypeSize.large, increasedContrast: true),
    (dark: true, size: DynamicTypeSize.large, increasedContrast: true),
    (dark: false, size: DynamicTypeSize.accessibility3, increasedContrast: true),
    (dark: true, size: DynamicTypeSize.accessibility3, increasedContrast: true),
  ])
  func selectedPinnedProgressKeepsPrimaryInkAndTextContrast(
    dark: Bool, size: DynamicTypeSize, increasedContrast: Bool
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 900, height: 800)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.accessibilityContrast = increasedContrast ? .high : .normal
    window.traitOverrides.preferredContentSizeCategory =
      size.isAccessibilitySize ? .accessibilityExtraLarge : .large
    let model = LibraryModel(
      snapshot: .init(notes: [
        .init(
          id: "pin", title: "A selected thought", updatedAt: .now, gistID: "pin",
          isPinned: true, progress: .init(completed: 2, total: 5)),
        .init(
          id: "quiet-pin", title: "Another pinned thought", updatedAt: .now,
          gistID: "quiet-pin", isPinned: true),
      ]), loadState: .ready)
    model.selectedNoteID = "pin"
    window.rootViewController = UIHostingController(
      rootView: NavigationSplitView {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: true)
      } detail: { Text("A retained document") }
      .environment(\.horizontalSizeClass, .regular)
      .environment(\.dynamicTypeSize, size)
      .environment(\.colorScheme, dark ? .dark : .light))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(500))
    window.layoutIfNeeded()
    let marker = try #require(descendants(window).first {
      $0.accessibilityIdentifier == "capture-frame-note-progress-pin" && !$0.bounds.isEmpty
    })
    let frame = marker.convert(marker.bounds, to: window).insetBy(dx: -2, dy: -2)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let crop = try #require(image.cgImage?.cropping(to: CGRect(
      x: frame.minX * image.scale, y: frame.minY * image.scale,
      width: frame.width * image.scale, height: frame.height * image.scale)))
    let background = try color(in: crop, at: .zero)
    let card = try #require(descendants(window).first {
      $0.accessibilityIdentifier == "capture-frame-note-card-pin" && !$0.bounds.isEmpty
    })
    let cardFrame = card.convert(card.bounds, to: window)
    let bitmap = try #require(image.cgImage)
    for distance in 1...4 {
      for y in [cardFrame.minY - CGFloat(distance), cardFrame.maxY + CGFloat(distance)] {
        let edge = try color(in: bitmap, at: CGPoint(
          x: cardFrame.midX * image.scale, y: y * image.scale))
        let sidebar = try color(in: bitmap, at: CGPoint(
          x: (cardFrame.minX - 4) * image.scale, y: y * image.scale))
        #expect(edge.contrast(with: sidebar) <= 1.02, "No selection tray outside the card: \(distance)")
      }
    }
    let list = try #require(descendants(window).compactMap { $0 as? UICollectionView }.first)
    #expect(list.indexPathsForSelectedItems?.isEmpty != false)
    #expect(model.selectedNoteID == "pin")
    let ink = try #require(RGBColor(
      uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
    let contrast = ink.contrast(with: background)
    #expect(contrast >= 4.5, "Contrast against actual native selected-card pixels: \(contrast)")
    #expect(try nativeAccentPixels(in: UIImage(cgImage: crop), expected: ink).personal > 10)
    Attachment.record(
      "Contrast: \(contrast), background: \(background), ink: \(ink)",
      named: "pinned-progress-\(dark ? "Dark" : "Light")-\(size)-\(increasedContrast)-contrast.txt")
    do {
      let quiet = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-card-quiet-pin" && !$0.bounds.isEmpty
      })
      let quietFrame = quiet.convert(quiet.bounds, to: window)
      let bitmap = try #require(image.cgImage)
      let surface = try color(in: bitmap, at: CGPoint(
        x: (quietFrame.minX + 2) * image.scale, y: quietFrame.midY * image.scale))
      let sidebar = try color(in: bitmap, at: CGPoint(
        x: (quietFrame.minX - 4) * image.scale, y: quietFrame.midY * image.scale))
      #expect(background.contrast(with: surface) >= 1.3)
      #expect(surface.hex == (dark ? "#3F4448" : "#F2F2F7"))
      #expect(background.hex == (dark ? "#51565A" : "#D1D1D6"))
      if dark {
        #expect(surface.contrast(with: .black) > sidebar.contrast(with: .black))
        #expect(background.contrast(with: .black) > surface.contrast(with: .black))
      }
      Attachment.record(
        "Sidebar: \(sidebar.hex), unselected: \(surface.hex), selected: \(background.hex)",
        named: "pinned-\(dark ? "Dark" : "Light")-surface-\(size)-\(increasedContrast).txt")
    }
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

  private func color(in bitmap: CGImage, at point: CGPoint) throws -> RGBColor {
    let corner = try #require(bitmap.cropping(to: CGRect(
      x: point.x, y: point.y, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return RGBColor(red: pixel[0], green: pixel[1], blue: pixel[2])
  }

}
