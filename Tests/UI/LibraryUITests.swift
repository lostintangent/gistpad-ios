import XCTest

@MainActor
final class LibraryUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testSectionsShowCountsAndOpenAGist() throws {
    let app = launchGistPad()
    let pinned = app.element("library-section-pinned")
    try waitUntil("the Library") { pinned.exists }
    XCTAssertEqual(pinned.label, "Pinned")
    XCTAssertEqual(pinned.countValue, "2 gists")
    for (collection, count) in [("dailyNotes", "4 daily notes"), ("starred", "1 gist"), ("archive", "1 gist")] {
      let header = app.element("library-collection-\(collection)")
      header.scrollIntoView(in: app)
      XCTAssertEqual(header.countValue, count, collection)
    }
    let weekend = app.element("library-note-weekend")
    weekend.scrollIntoView(in: app)
    weekend.tap()
    try waitUntil("the opened gist") {
      app.navigationBars["A slower weekend"].exists && app.noteShows("Farmers market")
    }
  }

  func testSidebarShowsTheOpenGistAndOneNewButton() throws {
    let app = launchGistPad(open: "shape/README.md")
    try waitUntil("the open gist") { app.navigationBars["The shape of a gist"].exists }
    guard app.isRegularWidth else { throw XCTSkip("The sidebar only shows when the Duo is open.") }
    let row = app.element("library-note-shape")
    try waitUntil("the sidebar to select the open gist") {
      row.isSelected || app.cells.containing(.any, identifier: "library-note-shape").firstMatch.isSelected
    }
    XCTAssertEqual(app.buttons.matching(identifier: "library-create").count, 1)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "library-today").count, 1)
  }

  /// Covers the posture it runs in. `XCUIDevice` can't fold or rotate the Duo in Simulator, so
  /// folding then unfolding, which used to strand Search in the detail, is checked by hand.
  func testSidebarKeepsSearchAndTagsInItsColumn() throws {
    let app = launchGistPad(open: "shape/README.md")
    try waitUntil("the open gist") { app.navigationBars["The shape of a gist"].exists }
    guard app.isRegularWidth else { throw XCTSkip("The sidebar only shows when the Duo is open.") }
    let showSidebar = app.buttons.matching(NSPredicate(format: "label == 'Show Sidebar'")).firstMatch
    if !app.element("library-note-shape").isHittable && showSidebar.isHittable { showSidebar.tap() }
    let column = app.navigationBars["GistPad"]
    let field = app.searchFields.firstMatch
    let tags = app.buttons["library-filter-tags"]
    try waitUntil("the sidebar's search field and Tags") { column.exists && field.isHittable && tags.isHittable }
    XCTAssertGreaterThanOrEqual(field.frame.minX, column.frame.minX)
    XCTAssertLessThan(field.frame.maxX, tags.frame.minX)
    XCTAssertLessThanOrEqual(tags.frame.maxX, column.frame.maxX)
  }

  func testSearchFindsAGistAndOpensIt() throws {
    let app = launchGistPad()
    try waitUntil("the Library") { app.element("library-note-shape").exists }
    app.search("weekend")
    let result = app.element("library-note-weekend")
    // The open note stays listed while filtering, so only other gists must leave.
    try waitUntil("the match") {
      result.isHittable && !app.element("library-note-shape").exists && !app.element("library-note-words").exists
    }
    result.tap()
    try waitUntil("the matching gist") { app.noteShows("Farmers market") }
  }

  func testTagFilterNarrowsTheListAndSearchKeepsIt() throws {
    let app = launchGistPad()
    try waitUntil("the Library") { app.element("library-note-weekend").exists }
    app.buttons["library-filter-tags"].tap()
    let ideas = app.buttons["library-tag-filter-ideas"]
    try waitUntil("the tag filter") { ideas.isHittable }
    ideas.tap()
    app.buttons["library-tag-filter-close"].tap()
    try waitUntil("the Ideas gists") {
      app.element("library-filter-count").label == "2 gists" && !app.element("library-note-weekend").exists
    }
    XCTAssertTrue(app.element("library-note-shape").exists)
    XCTAssertTrue(app.element("library-note-words").exists)

    app.search("words")
    try waitUntil("search inside the tag filter") {
      app.element("library-note-words").exists && !app.element("library-note-shape").exists
    }
    app.searchFields.firstMatch.buttons["Clear text"].tap()
    try waitUntil("the tag filter without the query") {
      app.element("library-note-words").exists && !app.element("library-note-weekend").exists
    }
    XCTAssertTrue(app.element("library-filter-clear").exists)
  }

  func testSwipeAndContextMenuPinArchiveAndDelete() throws {
    let app = launchGistPad()
    let weekend = app.element("library-note-weekend")
    try waitUntil("the Library") { weekend.isHittable }

    weekend.swipeRight()
    try tap(app.buttons["Pin"].firstMatch, "Pin")
    try waitUntil("three pins") { app.element("library-section-pinned").countValue == "3 gists" }

    let longTitle = app.element("library-note-longtitle")
    longTitle.scrollIntoView(in: app)
    longTitle.press(forDuration: 0.8)
    try tap(app.buttons["Archive"].firstMatch, "Archive")
    try waitUntil("two archived gists") { app.element("library-collection-archive").countValue == "2 gists" }

    let mixed = app.element("library-note-mixed")
    mixed.scrollIntoView(in: app)
    mixed.swipeLeft()
    try tap(app.buttons["Delete"].firstMatch, "Delete")
    try confirmDeletion(in: app)
    try waitUntil("mixed to leave the Library") { !mixed.exists }
  }

  func testANewGistCanBeDeletedRightAfterYouLeaveIt() throws {
    let app = launchGistPad()
    let create = app.buttons["library-create"].firstMatch
    try waitUntil("New Gist") { create.isHittable }
    create.tap()
    let editor = app.textViews["source-editor"]
    try waitUntil("the new gist's editor") { editor.isHittable && app.keyboards.firstMatch.exists }
    editor.typeText("# Gone soon\n\nA thought to delete.")

    // Leaving for the Library (or another gist, in the sidebar) publishes the new gist.
    if app.isRegularWidth { app.element("library-note-words").tap() } else { app.showLibrary() }
    let published = app.libraryRows.matching(
      NSPredicate(format: "identifier MATCHES 'library-note-f[0-9a-f]{7}'")).firstMatch
    try waitUntil("the published gist in the Library") { published.isHittable }
    let id = published.identifier
    published.swipeLeft()
    try tap(app.buttons["Delete"].firstMatch, "Delete")
    try confirmDeletion(in: app)
    try waitUntil("the new gist to leave the Library") { !app.element(id).exists }
  }

  func testRenameAndDeleteATag() throws {
    let app = launchGistPad(open: "shape/README.md", sheet: "tags")
    let ideas = app.buttons["tag-choice-ideas"]
    try waitUntil("the Tags sheet") { ideas.isHittable }

    ideas.swipeLeft()
    try tap(app.buttons["Edit Tag…"].firstMatch, "Edit Tag…")
    let name = app.textFields["Tag name"]
    try waitUntil("the tag form") { name.isHittable }
    name.tap()
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Big Ideas")
    app.buttons["tag-form-save"].tap()
    try waitUntil("the renamed tag") { ideas.label.contains("Big Ideas") }

    let design = app.buttons["tag-choice-design"]
    design.swipeLeft()
    try tap(app.buttons["Edit Tag…"].firstMatch, "Edit Tag…")
    let delete = app.buttons["Delete Tag"].firstMatch
    try waitUntil("Delete Tag") { delete.isHittable }
    delete.tap()
    try waitUntil("the delete confirmation") { app.buttons.matching(identifier: "Delete Tag").count > 1 }
    app.buttons.matching(identifier: "Delete Tag").allElementsBoundByIndex.last?.tap()
    try waitUntil("the deleted tag") { !design.exists }

    app.buttons["tag-save"].tap()
    try waitUntil("the saved tags") { !app.buttons["tag-save"].exists }
    app.buttons["note-actions"].tap()
    try tap(app.buttons["Tags"].firstMatch, "Tags")
    try waitUntil("the reopened Tags sheet") { ideas.isHittable }
    XCTAssertTrue(ideas.label.contains("Big Ideas"))
    XCTAssertFalse(design.exists)
  }
}

extension XCUIElement {
  /// Scrolls the Library until this element sits clear of the bottom search bar.
  func scrollIntoView(in app: XCUIApplication) {
    let list = app.element("library-list")
    for _ in 0..<8 where !(isHittable && frame.maxY < list.frame.maxY - 100) { list.swipeUp() }
  }

  /// A section header's count, without its Expanded or Collapsed state.
  var countValue: String? {
    (value as? String)?.components(separatedBy: ", ").first
  }
}
