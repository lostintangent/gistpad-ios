import XCTest

final class LibraryCollectionUITests: XCTestCase {
  @MainActor
  func testFoldedCollectionsHideUnknownAndEmptyOptionalScopes() async throws {
    try await checkCollections(wide: false)
  }

  @MainActor
  func testUnfoldedCollectionsHideUnknownAndEmptyOptionalScopes() async throws {
    try await checkCollections(wide: true)
  }

  @MainActor
  private func checkCollections(wide: Bool) async throws {
    for appearance in ["light", "dark"] {
      for state in ["collection-loading", "empty", "populated"] {
        let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
        app.launchArguments = [
          "--capture-screen", "library", "--capture-state", state,
          "--capture-appearance", appearance,
          "-AppleLocale", "en_US", "-AppleLanguages", "(en)",
          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()
        defer { app.terminate() }
        try await waitUntil("the actual \(wide ? "open" : "folded") Duo window") {
          let frame = app.windows.firstMatch.frame
          return abs(frame.width - (wide ? 951 : 466)) <= 1
            && abs(frame.height - (wide ? 669 : 678)) <= 1
        }
        let bar = app.navigationBars["GistPad"]
        let title = bar.buttons["GistPad"]
        try await waitUntil("the native collection title menu") { title.isHittable }
        if state == "collection-loading" {
          XCTAssertFalse(bar.staticTexts["0 gists"].exists)
          XCTAssertFalse(bar.staticTexts["5 gists"].exists)
        } else {
          XCTAssertTrue(bar.staticTexts[state == "empty" ? "0 gists" : "5 gists"].exists)
        }
        if wide && state == "populated" {
          let create = app.buttons["library-create"]
          let toggle = bar.buttons["Hide Sidebar"]
          let more = bar.buttons["More"]
          try await waitUntil("the native sidebar toggle and direct window Compose") {
            create.isHittable && toggle.isHittable && more.isHittable
          }
          XCTAssertEqual(app.buttons.matching(identifier: "library-create").count, 1)
          XCTAssertEqual(bar.buttons.matching(identifier: "Hide Sidebar").count, 1)
          XCTAssertEqual(
            bar.buttons.count, 3,
            "The native header contains only its title menu, More and one working sidebar toggle.")
          XCTAssertGreaterThanOrEqual(create.frame.minX, bar.frame.maxX - 1)
          let search = app.searchFields.firstMatch
          let first = app.descendants(matching: .any)["library-featured-shape"].firstMatch
          try await waitUntil("the row and full-width native Search column") {
            first.isHittable && search.exists && !search.frame.isEmpty
          }
          XCTAssertEqual(first.frame.minX, search.frame.minX, accuracy: 1)
          XCTAssertEqual(first.frame.width, search.frame.width, accuracy: 1)
          toggle.tap()
          let show = app.buttons["Show Sidebar"]
          try await waitUntil("the native control to reopen the hidden sidebar") {
            show.isHittable
          }
          XCTAssertEqual(app.buttons.matching(identifier: "Show Sidebar").count, 1)
          XCTAssertTrue(app.navigationBars["The shape of a notebook"].exists)
          show.tap()
          try await waitUntil("the restored sidebar and retained native row selection") {
            title.isHittable && toggle.isHittable && first.isHittable && first.isSelected
          }
          XCTAssertEqual(bar.buttons.count, 3)
        }
        title.tap()
        try await waitUntil("the two permanent collection choices") {
          app.buttons["All Notes"].exists && app.buttons["Daily Notes"].exists
        }
        XCTAssertEqual(app.buttons["Starred"].exists, state == "populated")
        XCTAssertEqual(app.buttons["Archive"].exists, state == "populated")
        record(
          app, name: "collections-\(wide ? "open" : "folded")-\(state)-\(appearance)")
        if wide && state == "populated" {
          app.buttons["Starred"].tap()
          let starredBar = app.navigationBars["Starred"]
          let retainedDetail = app.navigationBars["The shape of a notebook"]
          let starredRow = app.descendants(matching: .any)["library-note-starred"].firstMatch
          try await waitUntil("the scoped list with the same open detail") {
            starredBar.exists && retainedDetail.exists && starredRow.isHittable
          }
          XCTAssertFalse(starredRow.isSelected)
          let search = app.searchFields.firstMatch
          XCTAssertEqual(starredRow.frame.minX, search.frame.minX, accuracy: 1)
          XCTAssertEqual(starredRow.frame.width, search.frame.width, accuracy: 1)
          XCTAssertFalse(app.descendants(matching: .any)["library-featured-shape"].firstMatch.exists)
          XCTAssertFalse(app.descendants(matching: .any)["library-listed-heading"].firstMatch.exists)
          XCTAssertFalse(app.staticTexts["Open document"].exists)
          record(app, name: "retained-detail-outside-starred-open-\(appearance)")
          starredBar.buttons["Starred"].tap()
          try await waitUntil("the original Home choice") { app.buttons["All Notes"].isHittable }
          app.buttons["All Notes"].tap()
          let restored = app.descendants(matching: .any)["library-featured-shape"].firstMatch
          try await waitUntil("the retained note's native selection on returning Home") {
            restored.isHittable && restored.isSelected && retainedDetail.exists
          }
          record(app, name: "retained-detail-reselected-on-home-open-\(appearance)")
        }
      }
    }
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
    throw CollectionFailure.timedOut
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

private enum CollectionFailure: Error { case timedOut }
