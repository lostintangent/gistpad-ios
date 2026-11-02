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
        try await waitUntil("the stable Home title") { bar.exists }
        XCTAssertFalse(bar.buttons["GistPad"].exists)
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
          XCTAssertEqual(bar.buttons.count, 2)
          XCTAssertGreaterThanOrEqual(create.frame.minX, bar.frame.maxX - 1)
          let search = app.searchFields.firstMatch
          let first = app.buttons["library-note-shape"].firstMatch
          try await waitUntil("the pinned rows and full-width native Search column") {
            first.isHittable && search.exists && !search.frame.isEmpty
          }
          toggle.tap()
          let show = app.buttons["Show Sidebar"]
          try await waitUntil("the native control to reopen the hidden sidebar") {
            show.isHittable
          }
          XCTAssertEqual(app.buttons.matching(identifier: "Show Sidebar").count, 1)
          XCTAssertTrue(app.navigationBars["The shape of a notebook"].exists)
          show.tap()
          try await waitUntil("the restored sidebar and retained native row selection") {
            toggle.isHittable && first.isHittable && first.isSelected
          }
          XCTAssertEqual(bar.buttons.count, 2)
        }
        let list = app.collectionViews.firstMatch
        if state == "populated" {
          for section in [
            (id: "dailyNotes", title: "Daily Notes"),
            (id: "starred", title: "Starred Gists"),
            (id: "archive", title: "Archived Gists")
          ] {
            let header = app.descendants(matching: .any)
              .matching(identifier: "library-collection-\(section.id)").firstMatch
            for _ in 0..<8 {
              if header.isHittable { break }
              list.swipeUp()
            }
            try await waitUntil("the nonempty \(section.title) disclosure") { header.isHittable }
            XCTAssertEqual(header.label, section.title)
          }
        } else {
          XCTAssertEqual(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library-collection-")).count, 0)
        }
        record(
          app, name: "collections-\(wide ? "open" : "folded")-\(state)-\(appearance)")
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
