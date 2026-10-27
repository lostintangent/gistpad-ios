import XCTest
import UIKit

final class LibraryToolbarUITests: XCTestCase {
  @MainActor
  func testBottomSearchStaysVisibleAndStableWhileCheckingGitHub() async throws {
    for appearance in ["light", "dark"] {
      let idle = launch(state: "populated", appearance: appearance)
      let idleSearch = idle.searchFields.firstMatch
      try await waitUntil { idleSearch.isHittable }
      let originalFrame = idleSearch.frame
      idle.terminate()
      let app = launch(state: "status-busy", appearance: appearance)
      defer { app.terminate() }
      let search = app.searchFields.firstMatch
      try await waitUntil { search.isHittable }
      try await Task.sleep(for: .milliseconds(600))
      XCTAssertFalse(app.buttons["Search"].exists)
      XCTAssertFalse(app.buttons["library-search"].exists)
      XCTAssertEqual(search.frame, originalFrame, "Background checks never move or resize Search")
      XCTAssertFalse(app.progressIndicators["github-status-checking"].exists)
      XCTAssertFalse(app.buttons["github-status-attention"].exists)
      assertTarget(search, in: app)
      record(app, name: "home-search-checking-\(appearance)")
      search.tap()
      try await verifyNativeSearchAcceptsTyping(in: app)
      record(app, name: "home-search-active-while-checking-\(appearance)")
    }
  }

  @MainActor
  func testPersistentProblemKeepsSearchAndRecoveryAsSeparateActions() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(state: "status-error", appearance: appearance)
      defer { app.terminate() }
      let search = app.searchFields.firstMatch
      let attention = app.buttons["github-status-attention"]
      try await waitUntil { search.isHittable && attention.isHittable }
      XCTAssertEqual(search.value as? String, search.placeholderValue)
      XCTAssertFalse(search.frame.intersects(attention.frame))
      assertTarget(search, in: app)
      assertTarget(attention, in: app)
      record(app, name: "home-distinct-search-and-problem-\(appearance)")
      attention.tap()
      let retry = app.buttons["github-status-recover"]
      try await waitUntil { retry.isHittable && retry.isEnabled }
      retry.tap()
      try await waitUntil { retry.exists && !retry.isEnabled }
      try await waitUntil { !retry.exists && !attention.exists }
      try await waitUntil { search.isHittable }
      XCTAssertEqual(search.value as? String, search.placeholderValue)
      search.tap()
      try await verifyNativeSearchAcceptsTyping(in: app)
      record(app, name: "home-search-after-recovery-\(appearance)")
    }
  }

  @MainActor
  func testTagsAndSettingsAreDirectNativeToolbarActions() async throws {
    let app = launch(state: "populated", appearance: "light")
    defer { app.terminate() }
    let tags = app.buttons["library-filter-tags"]
    let settings = app.buttons["library-settings"]
    try await waitUntil { tags.isHittable && settings.isHittable }
    assertTarget(tags, in: app)
    assertTarget(settings, in: app)
    XCTAssertTrue(tags.label.contains("0"))
    tags.tap()
    try await waitUntil { app.navigationBars["Filter by tags"].exists }
    let idea = app.buttons["library-tag-filter-ideas"]
    try await waitUntil { idea.isHittable }
    idea.tap()
    app.buttons["library-tag-filter-done"].tap()
    try await waitUntil { tags.isHittable && tags.label.contains("1") }
    settings.tap()
    let callback = app.staticTexts["Settings opened for this synthetic notebook."]
    reveal(callback, in: app)
    try await waitUntil { callback.exists }
    record(app, name: "home-direct-settings-and-applied-tags")
  }

  @MainActor
  func testSearchSummaryAppearsOnlyForMultipleSelectedTags() async throws {
    let app = launch(state: "populated", appearance: "light")
    defer { app.terminate() }
    let summary = app.descendants(matching: .any)["library-search-tag-summary"].firstMatch
    let tags = app.buttons["library-filter-tags"]
    try await waitUntil { tags.isHittable }
    XCTAssertFalse(summary.exists)
    tags.tap()
    let ideas = app.buttons["library-tag-filter-ideas"]
    try await waitUntil { ideas.isHittable }
    ideas.tap()
    app.buttons["library-tag-filter-done"].tap()
    try await waitUntil { tags.isHittable && tags.label.contains("1") }
    XCTAssertFalse(summary.exists)
    tags.tap()
    let design = app.buttons["library-tag-filter-design"]
    try await waitUntil { design.isHittable }
    design.tap()
    app.buttons["library-tag-filter-done"].tap()
    try await waitUntil { summary.exists }
    XCTAssertEqual(summary.label, "Matches all selected tags.")
    XCTAssertFalse(app.otherElements["library-search-coverage"].exists)
    record(app, name: "home-search-multi-tag-only-summary")
    let field = app.searchFields.firstMatch
    field.tap()
    field.typeText("notebook")
    let clear = field.buttons["Clear text"]
    try await waitUntil { clear.isHittable }
    clear.tap()
    app.collectionViews.firstMatch.swipeUp()
    try await waitUntil { !app.keyboards.firstMatch.exists }
    XCTAssertTrue(summary.exists, "Ending empty text search preserves independent tag scope.")
    XCTAssertTrue(tags.label.contains("2"))
  }

  @MainActor
  func testFoldedHomeHeadersAndToolbarInLightDarkAndAccessibilitySizes() async throws {
    try await captureHome(wide: false)
  }

  @MainActor
  func testAccessibilitySearchKeepsPlaceholderAndClearInsideGlass() async throws {
    for textSize in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
      let sizeName = textSize == .large ? "Large" : "AX5"
      let app = launch(state: "populated", appearance: "light", textSize: textSize)
      defer { app.terminate() }
      let field = app.searchFields.firstMatch
      try await waitUntil { field.isHittable }
      record(app, name: "home-search-placeholder-clearance-\(sizeName)")
      field.tap()
      try await verifyNativeSearchAcceptsTyping(in: app)
      let clear = field.buttons["Clear text"]
      try await waitUntil { clear.isHittable }
      let magnifier = field.images["magnifyingglass"]
      XCTAssertTrue(magnifier.exists)
      let leadingClearance = magnifier.frame.minX - field.frame.minX
      let trailingClearance = field.frame.maxX - clear.frame.maxX
      XCTAssertGreaterThanOrEqual(trailingClearance, leadingClearance - 1)
      record(app, name: "home-search-query-clearance-\(sizeName)")
      clear.tap()
      try await waitUntil { (field.value as? String) == field.placeholderValue }
      XCTAssertTrue(app.keyboards.firstMatch.exists)
      record(app, name: "home-search-cleared-placeholder-\(sizeName)")
      XCTAssertFalse(app.buttons["Cancel"].exists)
      app.collectionViews.firstMatch.swipeUp()
      try await waitUntil { !app.keyboards.firstMatch.exists }
    }
  }

  @MainActor
  func testUnfoldedHomeKeepsNativeSearchAndOverflowInLightAndDark() async throws {
    try await captureHome(wide: true)
  }

  @MainActor
  func testUnfoldedSearchKeepsNativeClearAndSubmission() async throws {
    let app = launch(state: "populated", appearance: "light")
    defer { app.terminate() }
    let field = app.searchFields.firstMatch
    try await waitUntil { field.isHittable }
    field.tap()
    try await verifyNativeSearchAcceptsTyping(in: app)
    XCTAssertFalse(app.otherElements["library-search-coverage"].exists)
    XCTAssertFalse(app.staticTexts["Searches note titles."].exists)
    let clear = field.buttons["Clear text"]
    try await waitUntil { clear.isHittable }
    clear.tap()
    try await waitUntil { (field.value as? String) == field.placeholderValue }
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    field.typeText("notebook\n")
    try await waitUntil { !app.keyboards.firstMatch.exists }
    XCTAssertEqual(field.value as? String, "notebook")
    let matching = app.descendants(matching: .any)["library-note-shape"].firstMatch
    let excluded = app.descendants(matching: .any)["library-note-weekend"].firstMatch
    try await waitUntil { matching.exists && !excluded.exists }
    field.tap()
    try await waitUntil { app.keyboards.firstMatch.exists }
    app.collectionViews.firstMatch.swipeUp()
    try await waitUntil { !app.keyboards.firstMatch.exists }
    XCTAssertEqual(field.value as? String, "notebook")
    record(app, name: "home-open-native-active-field")
  }

  @MainActor
  func testFoldedBottomSearchClearsAndKeepsSubmittedResultsWithoutCancel() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(state: "populated", appearance: appearance)
      defer { app.terminate() }
      let field = app.searchFields.firstMatch
      try await waitUntil { field.isHittable }
      assertBottomSearch(field, in: app)
      field.tap()
      record(app, name: "home-bottom-search-after-tap-\(appearance)")
      try await verifyNativeSearchAcceptsTyping(in: app)
      let keyboard = app.keyboards.firstMatch
      XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY + 1)
      XCTAssertLessThan(keyboard.frame.minY - field.frame.maxY, 100)
      XCTAssertFalse(app.buttons["Cancel"].exists)
      XCTAssertFalse(app.otherElements["library-search-coverage"].exists)
      XCTAssertFalse(app.staticTexts["Searches note titles."].exists)
      let matching = app.descendants(matching: .any)["library-note-shape"].firstMatch
      let excluded = app.descendants(matching: .any)["library-note-weekend"].firstMatch
      try await waitUntil { matching.exists && !excluded.exists }
      record(app, name: "home-folded-bottom-search-keyboard-\(appearance)")
      let clear = field.buttons["Clear text"]
      try await waitUntil { clear.isHittable }
      clear.tap()
      try await waitUntil {
        keyboard.exists && (field.value as? String == field.placeholderValue)
      }
      app.collectionViews.firstMatch.swipeUp()
      try await waitUntil { !keyboard.exists }
      assertBottomSearch(field, in: app)
      let tags = app.buttons["library-filter-tags"]
      try await waitUntil { tags.isHittable }
      XCTAssertFalse(field.frame.intersects(tags.frame))
      record(app, name: "home-folded-bottom-search-cleared-\(appearance)")
      let last = app.descendants(matching: .any)["library-note-words"].firstMatch
      app.collectionViews.firstMatch.swipeUp()
      app.collectionViews.firstMatch.swipeUp()
      try await waitUntil { last.isHittable }
      XCTAssertLessThanOrEqual(last.frame.maxY, field.frame.minY)
      record(app, name: "home-last-row-clears-bottom-search-\(appearance)")
      field.tap()
      try await verifyNativeSearchAcceptsTyping(in: app)
      try await waitUntil { clear.isHittable }
      clear.tap()
      try await waitUntil { (field.value as? String) == field.placeholderValue }
      XCTAssertTrue(keyboard.exists)
      field.typeText("notebook\n")
      try await waitUntil { !keyboard.exists }
      XCTAssertEqual(field.value as? String, "notebook")
      XCTAssertTrue(tags.isHittable)
      field.tap()
      try await waitUntil { keyboard.exists }
      app.collectionViews.firstMatch.swipeUp()
      try await waitUntil { !keyboard.exists }
      XCTAssertEqual(field.value as? String, "notebook")
      try await waitUntil { matching.exists && !excluded.exists }
      record(app, name: "home-bottom-search-submitted-\(appearance)")
    }
  }

  @MainActor
  func testBottomSearchRetainsQueryAcrossUnfoldAndRefold() async throws {
    let app = launch(state: "populated", appearance: "light")
    defer { app.terminate() }
    let field = app.searchFields.firstMatch
    try await waitUntil { field.isHittable }
    field.tap()
    try await verifyNativeSearchAcceptsTyping(in: app)
    field.typeText("\n")
    try await waitUntil { !app.keyboards.firstMatch.exists }
    record(app, name: "home-query-before-unfold")
    try await waitForWidth(951, in: app)
    try await assertRetainedQuery(in: app)
    record(app, name: "home-query-retained-open")
    try await waitForWidth(466, in: app)
    try await assertRetainedQuery(in: app)
    assertBottomSearch(app.searchFields.firstMatch, in: app)
    record(app, name: "home-query-retained-refolded")
  }

  @MainActor
  func testCompactHorizontalToolbarKeepsBottomSearchSeparateAndAboveKeyboard() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(state: "populated", appearance: appearance, horizontalToolbar: true)
      defer { app.terminate() }
      let field = app.searchFields.firstMatch
      try await waitUntil { field.isHittable }
      XCTAssertFalse(app.buttons["Search"].exists)
      XCTAssertFalse(app.buttons["library-search"].exists)
      assertTarget(field, in: app)
      let tags = app.buttons["library-filter-tags"]
      XCTAssertTrue(tags.isHittable)
      XCTAssertFalse(field.frame.intersects(tags.frame))
      XCTAssertLessThan(field.frame.maxY, tags.frame.minY)
      XCTAssertGreaterThan(field.frame.minY, app.windows.firstMatch.frame.midY)
      record(app, name: "home-compact-horizontal-toolbar-\(appearance)")
      field.tap()
      try await verifyNativeSearchAcceptsTyping(in: app)
      XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
      record(app, name: "home-compact-horizontal-toolbar-keyboard-\(appearance)")
      XCTAssertFalse(app.buttons["Cancel"].exists)
      app.collectionViews.firstMatch.swipeUp()
      try await waitUntil { !app.keyboards.firstMatch.exists }
      assertTarget(field, in: app)
    }
  }

  @MainActor
  private func assertRetainedQuery(in app: XCUIApplication) async throws {
    try await waitUntil {
      let field = app.searchFields.firstMatch
      return field.isHittable && (field.value as? String) == "notebook"
    }
    XCTAssertEqual(app.searchFields.count, 1)
    XCTAssertFalse(app.buttons["Search"].exists)
    XCTAssertFalse(app.buttons["library-search"].exists)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(app.descendants(matching: .any)["library-note-shape"].firstMatch.exists)
    XCTAssertFalse(app.descendants(matching: .any)["library-note-weekend"].firstMatch.exists)
  }

  @MainActor
  private func waitForWidth(_ width: CGFloat, in app: XCUIApplication) async throws {
    let deadline = ContinuousClock.now + .seconds(150)
    while ContinuousClock.now < deadline {
      if abs(app.windows.firstMatch.frame.width - width) < 1 { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("The expected posture width \(width) did not appear.")
    throw ToolbarFailure.timedOut
  }

  @MainActor
  private func captureHome(wide: Bool) async throws {
    let appearances: [(String, UIContentSizeCategory)] = wide
      ? [("light", .large), ("dark", .large)]
      : [
        ("light", .large), ("dark", .large),
        ("light", .accessibilityExtraLarge), ("light", .accessibilityExtraExtraExtraLarge)
      ]
    for (appearance, textSize) in appearances {
      let accessibility = textSize.isAccessibilityCategory
      let sizeName = textSize == .accessibilityExtraExtraExtraLarge ? "AX5" : accessibility ? "AX3" : "Large"
      let app = launch(state: "populated", appearance: appearance, textSize: textSize)
      defer { app.terminate() }
      try await waitUntil { app.navigationBars["GistPad"].exists }
      record(app, name: "home-initial-\(wide ? "open" : "folded")-\(appearance)-\(sizeName)")
      let search = app.searchFields.firstMatch
      try await waitUntil {
        guard search.exists else { return false }
        let frame = search.frame
        guard !frame.isEmpty, app.windows.firstMatch.frame.contains(frame) else { return false }
        return search.isHittable
      }
      XCTAssertEqual(app.windows.firstMatch.frame.width, wide ? 951 : 466, accuracy: 1)
      XCTAssertEqual(app.windows.firstMatch.frame.height, wide ? 669 : 678, accuracy: 1)
      if wide {
        XCTAssertFalse(app.buttons["library-search"].exists)
        XCTAssertFalse(app.buttons["library-filter-tags"].exists
          && app.buttons["library-filter-tags"].isHittable)
        XCTAssertFalse(app.buttons["library-settings"].exists
          && app.buttons["library-settings"].isHittable)
        XCTAssertGreaterThan(search.frame.width, 180)
      } else {
        XCTAssertFalse(app.buttons["Search"].exists)
        XCTAssertFalse(app.buttons["library-search"].exists)
        assertBottomSearch(search, in: app)
        for id in ["library-filter-tags", "library-settings", "library-create"] {
          let target = app.buttons[id]
          XCTAssertTrue(target.isHittable, id)
          assertTarget(target, in: app)
        }
      }
      let title = app.navigationBars["GistPad"].descendants(matching: .any).matching(
        NSPredicate(format: "label BEGINSWITH %@", "GistPad")
      ).firstMatch
      XCTAssertTrue(title.exists)
      if !wide {
        XCTAssertFalse(title.frame.intersects(app.buttons["library-settings"].frame))
        XCTAssertFalse(title.frame.intersects(app.buttons["library-filter-tags"].frame))
        let create = app.buttons["library-create"].frame
        let settings = app.buttons["library-settings"].frame
        let tags = app.buttons["library-filter-tags"].frame
        XCTAssertLessThan(create.maxY, settings.midY)
        XCTAssertLessThan(settings.maxY, tags.midY)
        XCTAssertGreaterThan(tags.midY, app.windows.firstMatch.frame.maxY * 0.8)
        XCTAssertGreaterThan(tags.midY - settings.midY, 150)
        let tagsGlass = try toolbarGlassFrame(for: app.buttons["library-filter-tags"], in: app)
        if accessibility {
          XCTAssertEqual(tagsGlass.maxY, search.frame.maxY, accuracy: 2)
        } else {
          XCTAssertEqual(tagsGlass.midY, search.frame.midY, accuracy: 2)
        }
        XCTAssertFalse(tags.intersects(search.frame))
        XCTAssertEqual(create.midX, settings.midX, accuracy: 2)
        XCTAssertEqual(settings.midX, tags.midX, accuracy: 2)
        XCTAssertGreaterThan(tags.midX, app.windows.firstMatch.frame.midX)
      }
      let pinned = app.buttons["library-note-shape"].firstMatch
      try await waitUntil { pinned.exists }
      reveal(pinned, in: app)
      XCTAssertFalse(app.descendants(matching: .any)["library-pinned-heading"].exists)
      record(app, name: "home-\(wide ? "open" : "folded")-\(appearance)-\(sizeName)")
      let listed = app.descendants(matching: .any)["library-note-weekend"].firstMatch
      reveal(listed, in: app)
      try await waitUntil { listed.isHittable }
      XCTAssertFalse(app.descendants(matching: .any)["library-listed-heading"].exists)
      record(app, name: "home-your-gists-\(wide ? "open" : "folded")-\(appearance)-\(sizeName)")
      if wide {
        let more = app.navigationBars["GistPad"].buttons["More"]
        try await waitUntil { more.isHittable }
        more.tap()
        record(app, name: "home-open-overflow-\(appearance)")
        let tags = app.buttons.matching(
          NSPredicate(format: "label BEGINSWITH %@", "Filter by tags")).firstMatch
        let settings = app.buttons["Settings"]
        try await waitUntil { tags.isHittable && settings.isHittable }
        tags.tap()
        try await waitUntil { app.navigationBars["Filter by tags"].exists }
        app.buttons["library-tag-filter-done"].tap()
        try await waitUntil { more.isHittable }
        more.tap()
        try await waitUntil { settings.isHittable }
        settings.tap()
        let callback = app.staticTexts["Settings opened for this synthetic notebook."]
        reveal(callback, in: app)
        try await waitUntil { callback.exists }
        record(app, name: "home-open-overflow-routes-\(appearance)")
        search.tap()
        try await verifyNativeSearchAcceptsTyping(in: app)
        record(app, name: "home-open-keyboard-search-\(appearance)")
      }
    }
  }

  @MainActor
  private func toolbarGlassFrame(
    for button: XCUIElement, in app: XCUIApplication
  ) throws -> CGRect {
    let buttonFrame = button.frame
    let containers = app.otherElements.containing(.button, identifier: button.identifier)
    let glassFrame = containers.allElementsBoundByIndex.map(\.frame).filter {
      $0.contains(buttonFrame) && $0.width > buttonFrame.width && $0.height > buttonFrame.height
    }.min { $0.width * $0.height < $1.width * $1.height }
    return try XCTUnwrap(glassFrame, "The native toolbar glass must enclose its smaller button.")
  }

  @MainActor
  private func assertBottomSearch(
    _ field: XCUIElement, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    assertTarget(field, in: app, file: file, line: line)
    XCTAssertGreaterThan(field.frame.width, 180, file: file, line: line)
    XCTAssertGreaterThan(
      field.frame.midY, app.windows.firstMatch.frame.maxY * 0.8, file: file, line: line)
  }

  @MainActor
  private func verifyNativeSearchAcceptsTyping(in app: XCUIApplication) async throws {
    let field = app.searchFields.firstMatch
    try await waitUntil {
      guard field.exists, app.keyboards.firstMatch.exists else { return false }
      let frame = field.frame
      return !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }
    field.typeText("notebook")
    XCTAssertEqual(field.value as? String, "notebook")
  }

  @MainActor
  private func launch(
    state: String, appearance: String, textSize: UIContentSizeCategory = .large,
    horizontalToolbar: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", "library", "--capture-state", state,
      "--capture-appearance", appearance, "--capture-accent", "#FACC15",
      "-UIPreferredContentSizeCategoryName",
      textSize.rawValue
    ]
    if horizontalToolbar { app.launchArguments.append("--capture-horizontal-toolbar") }
    app.launch()
    return app
  }

  @MainActor
  private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<4 {
      if target.exists && target.isHittable { return }
      app.collectionViews.firstMatch.swipeUp()
    }
  }

  @MainActor
  private func assertTarget(
    _ target: XCUIElement, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(target.frame.isEmpty, file: file, line: line)
    XCTAssertTrue(target.isHittable, file: file, line: line)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(target.frame), file: file, line: line)
  }

  @MainActor
  private func waitUntil(_ ready: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("The expected native Library control did not become ready.")
    throw ToolbarFailure.timedOut
  }

  @MainActor
  private func record(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}

private enum ToolbarFailure: Error { case timedOut }
