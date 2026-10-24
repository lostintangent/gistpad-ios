import XCTest

final class LibraryToolbarUITests: XCTestCase {
  @MainActor
  func testSearchStillOpensTheNativeFieldWhileCheckingGitHub() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(state: "status-busy", appearance: appearance)
      defer { app.terminate() }
      let search = app.buttons["library-search"]
      try await waitUntil {
        search.isHittable && app.otherElements["capture-frame-library-search-progress"].exists
      }
      XCTAssertEqual(app.buttons.matching(identifier: "library-search").count, 1)
      XCTAssertFalse(app.progressIndicators["github-status-checking"].exists)
      XCTAssertFalse(app.buttons["github-status-attention"].exists)
      assertTarget(search, in: app)
      record(app, name: "home-search-checking-\(appearance)")
      search.tap()
      record(app, name: "home-search-immediately-after-checking-tap-\(appearance)")
      try await verifyNativeSearchAcceptsTyping(in: app)
      record(app, name: "home-search-active-while-checking-\(appearance)")
    }
  }

  @MainActor
  func testPersistentProblemKeepsSearchAndRecoveryAsSeparateActions() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(state: "status-error", appearance: appearance)
      defer { app.terminate() }
      let search = app.buttons["library-search"]
      let attention = app.buttons["github-status-attention"]
      try await waitUntil { search.isHittable && attention.isHittable }
      XCTAssertTrue((search.value as? String ?? "").isEmpty)
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
      try await waitUntil {
        (search.value as? String ?? "").isEmpty
          && !app.otherElements["capture-frame-library-search-progress"].exists
      }
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
  func testFoldedHomeHeadersAndToolbarInLightDarkAndAX3() async throws {
    try await captureHome(wide: false)
  }

  @MainActor
  func testUnfoldedHomeKeepsNativeSearchAndOverflowInLightAndDark() async throws {
    try await captureHome(wide: true)
  }

  @MainActor
  private func captureHome(wide: Bool) async throws {
    let appearances = wide
      ? [("light", false), ("dark", false)]
      : [("light", false), ("dark", false), ("light", true)]
    for (appearance, accessibility) in appearances {
      let app = launch(state: "populated", appearance: appearance, accessibility: accessibility)
      defer { app.terminate() }
      let search = wide ? app.searchFields.firstMatch : app.buttons["library-search"]
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
        for id in ["library-search", "library-filter-tags", "library-settings", "library-create"] {
          let target = app.buttons[id]
          XCTAssertTrue(target.isHittable, id)
          assertTarget(target, in: app)
        }
      }
      let title = app.navigationBars["GistPad"].buttons["GistPad"]
      XCTAssertTrue(title.exists)
      if !wide {
        XCTAssertFalse(title.frame.intersects(app.buttons["library-settings"].frame))
        XCTAssertFalse(title.frame.intersects(app.buttons["library-filter-tags"].frame))
        XCTAssertLessThan(app.buttons["library-create"].frame.midY, app.buttons["library-settings"].frame.midY)
        XCTAssertLessThan(app.buttons["library-filter-tags"].frame.midY, search.frame.midY)
      }
      let pinned = app.descendants(matching: .any)["library-pinned-heading"].firstMatch
      try await waitUntil { pinned.exists }
      reveal(pinned, in: app)
      XCTAssertEqual(pinned.label, "Pinned Gists, 2 gists")
      record(app, name: "home-\(wide ? "open" : "folded")-\(appearance)-\(accessibility ? "AX3" : "Large")")
      let listed = app.descendants(matching: .any)["library-listed-heading"].firstMatch
      reveal(listed, in: app)
      try await waitUntil { listed.isHittable }
      XCTAssertEqual(listed.label, "Your Gists, 3 gists")
      record(app, name: "home-your-gists-\(wide ? "open" : "folded")-\(appearance)-\(accessibility ? "AX3" : "Large")")
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
      }
    }
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
    state: String, appearance: String, accessibility: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", "library", "--capture-state", state,
      "--capture-appearance", appearance, "--capture-accent", "#FACC15",
      "-UIPreferredContentSizeCategoryName",
      accessibility ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
    ]
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
