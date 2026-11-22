import XCTest

@MainActor
final class GistUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testModesSwitchWhileTheChromeStays() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let title = app.navigationBars["The shape of a gist"]
    let modes = app.segmentedControls["note-toggle-mode"]
    try waitUntil("Edit") { title.exists && modes.buttons["Edit"].isSelected }
    app.dismissSidebarOverlay()

    modes.buttons["Preview"].tap()
    try waitUntil("Preview") { modes.buttons["Preview"].isSelected && app.webViews.firstMatch.exists }
    XCTAssertTrue(title.exists)
    XCTAssertTrue(app.moreButton.exists)

    // Split joins the picker when the note is wide enough for two panes.
    if modes.buttons["Split"].exists {
      modes.buttons["Split"].tap()
      try waitUntil("Split") { modes.buttons["Split"].isSelected }
    }

    modes.buttons["Edit"].tap()
    try waitUntil("Edit again") { modes.buttons["Edit"].isSelected && app.textViews["source-editor"].isTappable }
    XCTAssertTrue(title.exists)
  }

  func testEditWaitsForATapAndPutsTheCaretWhereYouTapped() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    let modes = app.segmentedControls["note-toggle-mode"]
    try waitUntil("README.md") { editor.text?.hasPrefix("# A considered") == true }
    app.dismissSidebarOverlay()
    try tap(modes.buttons["Preview"], "Preview")
    try waitUntil("Preview") { modes.buttons["Preview"].isSelected }
    try tap(modes.buttons["Edit"], "Edit")
    try waitUntil("Edit") { modes.buttons["Edit"].isSelected && editor.isTappable }
    XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2), "Edit raised the keyboard")

    // Leave a caret near the end, then tap near the top with the keyboard down.
    for _ in 0..<3 { editor.swipeUp(velocity: .slow) }
    editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    try waitUntil("the keyboard") { app.keyboards.firstMatch.exists }
    try tap(app.buttons["Hide Keyboard"], "Hide Keyboard")
    try waitUntil("the keyboard to go") { !app.keyboards.firstMatch.exists }
    for _ in 0..<4 { editor.swipeDown(velocity: .slow) }
    editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    try waitUntil("the keyboard") { app.keyboards.firstMatch.exists }
    app.typeText("Z")
    // The editor's value holds only the note's first 512 characters, which a Z typed after
    // scrolling back to the old caret wouldn't reach.
    try waitUntil("Z near the top, where it was tapped") { editor.text?.contains("Z") == true }
  }

  func testATapPutsTheCaretUnderTheFinger() throws {
    let app = launchGistPad("empty")
    let today = app.element("library-today")
    try waitUntil("Today") { today.isTappable }
    app.dismissSidebarOverlay()
    today.tap()
    let editor = app.textViews["source-editor"]
    try waitUntil("today's note") { editor.isTappable && app.keyboards.firstMatch.exists }
    // Below the date heading and a blank line, lines 2 to 7 each hold one long word.
    editor.typeText(String(repeating: "Uncharacteristically\n", count: 6))

    let frame = editor.frame
    let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY) + 24
    func point(line: Int, x: CGFloat) -> XCUICoordinate {
      app.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: frame.minX + 25 + x, dy: top + 22 * (CGFloat(line) + 0.5)))
    }
    func line(_ index: Int) -> String? {
      editor.text?.components(separatedBy: "\n").dropFirst(index).first
    }
    // The word snapping a stock tap does would put the mark at either end instead.
    func landedInside(_ mark: String, line index: Int) -> Bool {
      guard let text = line(index), text.count == 20 + mark.count, let found = text.range(of: mark)
      else { return false }
      return found.lowerBound != text.startIndex && found.upperBound != text.endIndex
    }

    point(line: 2, x: 80).tap()
    app.typeText("A")
    try waitUntil("A in the middle of the word") { landedInside("A", line: 2) }

    // Fixing a typo in the word you're typing is one tap, without the caret's menu.
    point(line: 3, x: 150).tap()
    point(line: 3, x: 40).tap()
    app.typeText("B")
    try waitUntil("B where it was tapped, in the caret's word") { landedInside("B", line: 3) }

    // A tap on the caret still shows its menu, and leaves the caret where it was.
    point(line: 4, x: 60).tap()
    app.typeText("C")
    try waitUntil("C in the middle of the word") { landedInside("C", line: 4) }
    point(line: 4, x: 60).tap()
    try waitUntil("the caret's menu") { app.menuItems["Select All"].exists }
    app.typeText("c")
    try waitUntil("c right after C") { landedInside("Cc", line: 4) }

    point(line: 5, x: 80).doubleTap()
    try waitUntil("the selection's menu") { app.menuItems["Copy"].exists }
    app.typeText("D")
    try waitUntil("D in place of the double-tapped word") { line(5) == "D" }

    try tap(app.buttons["Hide Keyboard"], "Hide Keyboard")
    try waitUntil("the keyboard to go") { !app.keyboards.firstMatch.exists }
    point(line: 6, x: 80).tap()
    try waitUntil("the keyboard") { app.keyboards.firstMatch.exists }
    app.typeText("E")
    try waitUntil("E in the middle of the word") { landedInside("E", line: 6) }
  }

  func testSwitchingFiles() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    let title = app.buttons["note-title"]
    // README.md is the gist's front page, so the title stands alone without a filename.
    try waitUntil("README.md") { editor.text?.hasPrefix("# A considered") == true }
    XCTAssertEqual(title.value as? String, "")
    app.dismissSidebarOverlay()

    try tap(title, "the title")
    try tap(app.buttons["Ideas.md"].firstMatch, "Ideas.md")
    try waitUntil("Ideas.md") { editor.text?.hasPrefix("# Ideas") == true }
    XCTAssertEqual(title.value as? String, "Ideas.md")
  }

  func testAddLinkOpensReadyForItsURL() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    try waitUntil("the editor") { editor.exists }
    app.dismissSidebarOverlay()
    try tap(editor, "the editor")
    try tap(app.buttons["editor-insert-menu"], "Insert")
    try tap(app.buttons["Link"].firstMatch, "Link")
    let url = app.textFields["link-url"]
    // The editor's keyboard is already up, so wait for the URL field itself to take it.
    let focusedURL = app.textFields.matching(NSPredicate(format: "hasKeyboardFocus == true"))
      .matching(identifier: "link-url").firstMatch
    try waitUntil("Add Link with its URL field focused") { focusedURL.exists }

    // Typing without a tap proves the URL field, not the Text field or the editor, has focus.
    app.typeText("gistpad.dev")
    try waitUntil("the typed URL") { url.text == "gistpad.dev" }
  }
}
