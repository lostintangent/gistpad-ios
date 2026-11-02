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
    var image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let list = try #require(descendants(window).compactMap { $0 as? UICollectionView }.first)
    let ordinary = try #require(descendants(window).first {
      $0.accessibilityIdentifier == "capture-frame-note-title-ordinary"
    })
    var ordinaryParent = ordinary.superview
    while ordinaryParent != nil && !(ordinaryParent is UICollectionViewCell) {
      ordinaryParent = ordinaryParent?.superview
    }
    let ordinaryCell = try #require(ordinaryParent as? UICollectionViewCell)
    let ordinaryFrame = ordinaryCell.convert(ordinaryCell.bounds, to: window)
      .offsetBy(dx: 0, dy: list.contentOffset.y)
    var headerFrames: [CGRect] = []
    var countContrasts: [Double] = []
    var firstContentFrame: CGRect?
    for collection in [LibraryCollection.dailyNotes, .starred, .archive] {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)"
          && !$0.bounds.isEmpty
      })
      var parent = marker.superview
      while parent != nil && !(parent is UICollectionViewCell) { parent = parent?.superview }
      let cell = try #require(parent as? UICollectionViewCell)
      // The sidebar's floating search field overlaps the list's bottom content inset.
      let search = descendants(window).first {
        $0 is UISearchTextField && !$0.isHidden && !$0.bounds.isEmpty
      }
      let searchTop = search.map { $0.convert($0.bounds, to: window).minY - 8 }
      let bottomClearance = max(
        list.adjustedContentInset.bottom,
        list.convert(list.bounds, to: window).maxY - (searchTop ?? .infinity))
      if cell.frame.maxY > list.bounds.maxY - bottomClearance {
        let maximum = max(
          -list.adjustedContentInset.top,
          list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
        let target = min(maximum, cell.frame.maxY - list.bounds.height + bottomClearance + 8)
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: target), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
      }
      #expect(window.bounds.contains(marker.convert(marker.bounds, to: window)))
      let cellFrame = cell.convert(cell.bounds, to: window)
      if let searchTop {
        #expect(cellFrame.maxY <= searchTop + 8, "The header scrolls clear of the search field.")
      }
      headerFrames.append(cellFrame.offsetBy(dx: 0, dy: list.contentOffset.y))
      if firstContentFrame == nil {
        firstContentFrame = marker.convert(marker.bounds, to: window)
          .offsetBy(dx: 0, dy: list.contentOffset.y)
      }
      image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let bitmap = try #require(image.cgImage)
      let count = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)-count"
          && !$0.bounds.isEmpty
      })
      let title = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)-title"
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
      // The count is quiet secondary ink. The glass sidebar draws hierarchical `.secondary`
      // with vibrancy, so measure the drawn glyph core rather than a fixed UIKit color.
      let countContrast = try strongestInk(in: countCrop, against: background)
        .contrast(with: background)
      let primary = try #require(RGBColor(
        uiColor: UIColor.label.resolvedColor(with: window.traitCollection)))
      #expect(countContrast >= 3, "The count stays legible: \(countContrast)")
      #expect(
        countContrast < primary.contrast(with: background) / 2,
        "The count reads as secondary, not primary: \(countContrast)")
      countContrasts.append(countContrast)
    }
    for index in 1..<headerFrames.count {
      #expect(headerFrames[index].minY > headerFrames[index - 1].minY)
      #expect(headerFrames[index - 1].maxY <= headerFrames[index].minY + 1 / image.scale)
    }
    let firstHeader = try #require(firstContentFrame)
    #expect(firstHeader.minY >= ordinaryFrame.maxY - 1 / image.scale)
    Attachment.record(
      "Headers: \(headerFrames)\nOrdinary cell: \(ordinaryFrame)\nFirst content: \(firstHeader)"
        + "\nCount contrasts: \(countContrasts)",
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
      descendants(window).contains {
        $0.accessibilityIdentifier == "capture-frame-library-collection-\(collection.rawValue)"
          && !$0.bounds.isEmpty && isShownOnScreen($0)
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
  func taggedRowsKeepTheDateBesideTheTitleAndTheCountBesideTheTags(size: DynamicTypeSize) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.traitOverrides.preferredContentSizeCategory =
      size == .large ? .large : .accessibilityExtraLarge
    let note = LibraryNote(
      id: "metadata", title: "Words worth keeping",
      updatedAt: .now.addingTimeInterval(-172_800), gistID: "metadata", tagIDs: ["ideas"],
      fileCount: 3, commentCount: 2)
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
    func frame(_ part: String) throws -> CGRect {
      let marker = try #require(descendants(window).first {
        $0.accessibilityIdentifier == "capture-frame-note-\(part)-metadata" && !$0.bounds.isEmpty
      })
      return marker.convert(marker.bounds, to: window)
    }
    let title = try frame("title")
    let date = try frame("date")
    let tagLine = try frame("tags")
    let count = try frame("comment-count")
    #expect(measured.width == 324)
    #expect(tagLine.minY >= max(title.maxY, date.maxY))
    if size == .large {
      #expect(date.midY > title.minY && date.midY < title.maxY)
      #expect(date.minX >= title.maxX)
      #expect(count.midY > tagLine.minY && count.midY < tagLine.maxY)
      #expect(count.minX >= tagLine.maxX)
      #expect(measured.height <= 100)
      #expect(tagLine.height <= 30)
    } else {
      // Accessibility sizes stack leading-aligned: title, count and date, then only tags.
      #expect(date.minY >= title.maxY)
      #expect(count.midY > date.minY && count.midY < date.maxY)
      #expect(count.maxX <= date.minX)
      #expect(abs(count.minX - title.minX) <= 1)
      #expect(measured.height > 128)
      #expect(tagLine.height > 30)
    }
  }

  @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility3])
  func pinnedNotesAreOrdinaryRowsAboveTheDateGroups(
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
    let pinned = try frame("note-content-pin")
    let ordinary = try frame("note-content-ordinary")
    #expect(pinned.minY < ordinary.minY)
    #expect(abs(pinned.width - ordinary.width) <= 1)
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
  func selectedDailyProgressKeepsVisibleRingContrast(
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
          id: "pin", title: "2026-10-23", updatedAt: .now, gistID: "daily", isDailyNote: true,
          filename: "2026-10-23.md", progress: .init(completed: 2, total: 5),
          dailyDate: ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z")),
        .init(
          id: "quiet-pin", title: "Another pinned thought", updatedAt: .now,
          gistID: "quiet-pin", isPinned: true),
      ], dailyNoteCount: 1), loadState: .ready)
    model.selectedNoteID = "pin"
    window.rootViewController = UIHostingController(
      rootView: NavigationSplitView {
        LibraryView(
          model: model, actions: .init(refresh: {}, create: {}, today: {}), isSidebar: true,
          expandedCollections: .constant([.dailyNotes]))
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
    let list = try #require(descendants(window).compactMap { $0 as? UICollectionView }.first)
    #expect(list.indexPathsForSelectedItems?.isEmpty == false)
    #expect(model.selectedNoteID == "pin")
    let contrast = try maximumContrast(of: crop, against: background)
    #expect(contrast >= 3, "The ring needs 3:1 against the native selected row: \(contrast)")
    Attachment.record(
      "Contrast: \(contrast), background: \(background)",
      named: "daily-progress-\(dark ? "Dark" : "Light")-\(size)-\(increasedContrast)-contrast.txt")
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
      rootView: NavigationStack {
        LibraryView(model: model, actions: .init(refresh: {}, create: {}, today: {}))
      }
      .librarySearch(model: model, isPresented: .constant(true), isSidebar: false)
      .environment(\.horizontalSizeClass, .compact)
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
    Attachment.record(
      image, named: "library-search-Compact-\(dark ? "Dark" : "Light")-Large.png",
      as: .png)
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
    for id in ["library-tag-filter-ideas", "library-tag-filter-work"] {
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

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func isShownOnScreen(_ view: UIView) -> Bool {
    var cursor: UIView? = view
    while let current = cursor {
      if current.isHidden || current.alpha == 0 { return false }
      cursor = current.superview
    }
    return true
  }

  private func maximumContrast(of bitmap: CGImage, against background: RGBColor) throws -> Double {
    let width = bitmap.width
    let height = bitmap.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { best, index in
      let pixel = RGBColor(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2])
      return max(best, pixel.contrast(with: background))
    }
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

  /// The pixel that differs most from the background, which is the core of a glyph's ink.
  private func strongestInk(in bitmap: CGImage, against background: RGBColor) throws -> RGBColor {
    let width = bitmap.width
    let height = bitmap.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
      let context = try #require(CGContext(
        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return stride(from: 0, to: pixels.count, by: 4)
      .map { RGBColor(red: pixels[$0], green: pixels[$0 + 1], blue: pixels[$0 + 2]) }
      .max { $0.contrast(with: background) < $1.contrast(with: background) } ?? background
  }

}
