import XCTest

final class NotebookShelfUITests: XCTestCase {
  @MainActor
  func testFoldedHomeUsesOneNativePinnedRowList() async throws {
    try await checkHome(wide: false)
  }

  @MainActor
  func testUnfoldedHomeUsesTheSameNativePinnedRowList() async throws {
    try await checkHome(wide: true)
  }

  @MainActor
  func testFoldedDailyTitlesAndCountsAtLargeAndAccessibilitySizes() async throws {
    try await checkDaily(wide: false)
  }

  @MainActor
  func testUnfoldedDailyTitlesAndCountsAtLargeAndAccessibilitySizes() async throws {
    try await checkDaily(wide: true)
  }

  @MainActor
  private func checkHome(wide: Bool) async throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        let app = launch(
          state: accessibility ? "row-anatomy" : "populated",
          appearance: appearance, accessibility: accessibility)
        defer { app.terminate() }
        try await checkPosture(app, wide: wide)
        let first = row("library-featured-shape", in: app)
        let second = row("library-featured-small", in: app)
        let name = "\(wide ? "open" : "folded")-\(accessibility ? "AX3" : "Large")-\(appearance)"
        let detailTitle = accessibility
          ? "📚 A longer thought about the things we choose to keep close"
          : "The shape of a notebook"
        try await reveal(first, in: app)
        XCTAssertTrue(first.label.contains("A quiet place to think"))
        XCTAssertFalse(first.label.contains("2 files"))
        XCTAssertFalse(first.label.contains(".md"))
        XCTAssertTrue((first.value as? String)?.contains("Pinned") == true)
        if accessibility {
          XCTAssertTrue(first.label.contains("📚 A longer thought"))
          XCTAssertTrue(first.label.contains("4 of 4 tasks complete"))
          XCTAssertTrue(first.label.contains("Personal"))
          XCTAssertTrue((first.value as? String)?.contains("Starred") == true)
          XCTAssertTrue((first.value as? String)?.contains("Public gist") == true)
        } else {
          XCTAssertTrue((first.value as? String)?.contains("Unlisted gist") == true)
        }
        if wide {
          try await checkMatchingDetail(detailTitle, in: app)
        }
        record(app, name: "notebook-shelf-\(name)")

        try await reveal(second, in: app)
        XCTAssertTrue(second.label.contains("A notebook can be both quiet"))
        if !accessibility {
          XCTAssertGreaterThanOrEqual(second.frame.minY, first.frame.maxY - 1)
          XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
          XCTAssertEqual(first.frame.width, second.frame.width, accuracy: 1)
        } else {
          let draft = row("library-note-local-draft", in: app)
          try await reveal(draft, in: app)
          XCTAssertTrue(draft.label.contains("Not published yet."))
          XCTAssertTrue((draft.value as? String)?.contains("On this iPhone") == true)
          XCTAssertFalse(draft.label.contains("README.md"))
          record(app, name: "notebook-local-draft-\(name)")
        }

        try await reveal(first, in: app, backwards: true)
        if !wide {
          first.tap()
          try await checkMatchingDetail(detailTitle, in: app)
          record(app, name: "notebook-native-detail-\(name)")
          let back = app.buttons["BackButton"]
          try await waitUntil("the native Back control") {
            back.isHittable
          }
          back.tap()
          try await waitUntil("the same unselected compact row after Back") {
            first.isHittable && !first.isSelected
          }
        }
        let touchRect = try XCTUnwrap(visibleTouchRect(for: first, in: app))
        let origin = first.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(
          dx: touchRect.midX - first.frame.minX,
          dy: touchRect.midY - first.frame.minY))
          .press(forDuration: 0.8)
        record(app, name: "notebook-shelf-after-native-press-\(name)")
        try await waitUntil("the pinned row's native context actions") {
          app.buttons["Unpin"].isHittable && app.buttons["Archive"].isHittable
        }
        record(app, name: "notebook-shelf-native-actions-\(name)")
      }
    }
  }

  @MainActor
  private func checkDaily(wide: Bool) async throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        let app = launch(
          state: "daily-progress", appearance: appearance, accessibility: accessibility)
        defer { app.terminate() }
        try await checkPosture(app, wide: wide)
        let overdue = row("library-note-daily-overdue", in: app)
        let header = app.buttons["library-collection-dailyNotes"].firstMatch
        for _ in 0..<4 {
          if overdue.isHittable { break }
          app.collectionViews.firstMatch.swipeUp()
        }
        try await waitUntil("the readable day and truthful note total") {
          overdue.isHittable && (header.value as? String ?? "").contains("2 notes")
        }
        XCTAssertTrue(overdue.label.contains("Friday"))
        XCTAssertTrue(overdue.label.contains("2026"))
        XCTAssertFalse(overdue.label.contains("2026-10-23"))
        XCTAssertTrue(overdue.label.contains("3 of 4 tasks complete"))
        XCTAssertTrue(overdue.label.contains("Unfinished tasks"))
        XCTAssertTrue(overdue.label.contains("Set up the iPhone Duo"))
        XCTAssertFalse(overdue.label.contains(".md"))
        XCTAssertFalse(overdue.label.contains("3 files"))
        XCTAssertFalse(overdue.label.contains("ago"))
        record(
          app,
          name: "daily-shelf-\(wide ? "open" : "folded")-\(accessibility ? "AX3" : "Large")-\(appearance)")

        let complete = row("library-note-today", in: app)
        for _ in 0..<4 {
          if complete.isHittable { break }
          app.collectionViews.firstMatch.swipeUp()
        }
        try await waitUntil("the completed day in the same native list") { complete.isHittable }
        XCTAssertTrue(complete.label.contains("Saturday"))
        XCTAssertTrue(complete.label.contains("1 of 1 tasks complete"))
        XCTAssertFalse(complete.label.contains("2026-10-24"))
      }
    }
  }

  @MainActor
  private func launch(
    state: String, appearance: String, accessibility: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", "library", "--capture-state", state,
      "--capture-appearance", appearance, "--capture-accent", "#FACC15",
      "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
      "-UIPreferredContentSizeCategoryName",
      accessibility ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL",
    ]
    app.launch()
    return app
  }

  @MainActor
  private func checkPosture(_ app: XCUIApplication, wide: Bool) async throws {
    try await waitUntil("the actual \(wide ? "open" : "folded") Duo window") {
      let frame = app.windows.firstMatch.frame
      return abs(frame.width - (wide ? 951 : 466)) <= 1
        && abs(frame.height - (wide ? 669 : 678)) <= 1
    }
  }

  @MainActor
  private func row(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  @MainActor
  private func checkMatchingDetail(_ title: String, in app: XCUIApplication) async throws {
    try await waitUntil("the matching native title and rendered document heading") {
      app.navigationBars[title].exists
        && app.webViews.staticTexts[title].firstMatch.exists
    }
  }

  @MainActor
  private func reveal(
    _ element: XCUIElement, in app: XCUIApplication, backwards: Bool = false
  ) async throws {
    for _ in 0..<8 {
      if visibleTouchRect(for: element, in: app) != nil { return }
      if backwards {
        app.collectionViews["library-list"].swipeDown()
      } else {
        app.collectionViews["library-list"].swipeUp()
      }
    }
    try await waitUntil("the note row while scrolling") {
      visibleTouchRect(for: element, in: app) != nil
    }
  }

  @MainActor
  private func visibleTouchRect(
    for element: XCUIElement, in app: XCUIApplication
  ) -> CGRect? {
    guard element.exists, element.isHittable else { return nil }
    let list = app.collectionViews["library-list"].frame
    let top = max(list.minY, app.navigationBars["GistPad"].frame.maxY)
    let search = app.searchFields.firstMatch
    let bottom = search.exists ? min(list.maxY, search.frame.minY) : list.maxY
    let visible = element.frame.intersection(
      CGRect(x: list.minX, y: top, width: list.width, height: max(0, bottom - top)))
    guard !visible.isNull, visible.width >= 44, visible.height >= 44 else { return nil }
    return visible
  }

  @MainActor
  private func waitUntil(
    _ description: String, file: StaticString = #filePath, line: UInt = #line,
    _ ready: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Timed out waiting for \(description).", file: file, line: line)
    throw NotebookShelfFailure.timedOut
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

private enum NotebookShelfFailure: Error { case timedOut }
