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
    let url = app.textFields["URL"]
    try waitUntil("Add Link with its keyboard") { url.exists && app.keyboards.firstMatch.exists }

    // Typing without a tap proves the URL field, not the Text field or the editor, has focus.
    app.typeText("gistpad.dev")
    XCTAssertEqual(url.value as? String, "gistpad.dev")
  }
}
