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
    try waitUntil("Edit again") { modes.buttons["Edit"].isSelected && app.textViews["source-editor"].isHittable }
    XCTAssertTrue(title.exists)
  }

  func testSwitchingFiles() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    // README.md is the gist's front page, so the title stands alone without a filename.
    try waitUntil("README.md") { (editor.value as? String)?.hasPrefix("# A considered") == true }

    try openNoteActions(in: app)
    try tap(app.buttons["Files"].firstMatch, "Files")
    try tap(app.buttons["Ideas.md"].firstMatch, "Ideas.md")
    try waitUntil("Ideas.md") { (editor.value as? String)?.hasPrefix("# Ideas") == true }
    XCTAssertTrue(app.navigationBars.staticTexts["Ideas.md"].exists)
  }

  func testAddLinkOpensReadyForItsURL() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    try waitUntil("the editor") { editor.exists }
    app.dismissSidebarOverlay()
    try tap(editor, "the editor")
    try tap(app.buttons["editor-insert-menu"], "Insert")
    try tap(app.buttons["Link…"].firstMatch, "Link…")
    let url = app.textFields["URL"]
    try waitUntil("Add Link with its keyboard") { url.exists && app.keyboards.firstMatch.exists }

    // Typing without a tap proves the URL field, not the Text field or the editor, has focus.
    app.typeText("gistpad.dev")
    XCTAssertEqual(url.value as? String, "gistpad.dev")
  }
}
