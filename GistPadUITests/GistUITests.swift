import XCTest

@MainActor
final class GistUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testModesSwitchWhileTheChromeStays() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let title = app.navigationBars["The shape of a notebook"]
    let editor = app.textViews["source-editor"]
    let preview = app.webViews.firstMatch
    let modes = app.segmentedControls["note-toggle-mode"]
    try waitUntil("Edit") { title.exists && editor.exists && modes.exists }

    modes.buttons["Preview"].tap()
    try waitUntil("Preview") { preview.exists && !editor.exists }
    XCTAssertTrue(title.exists)
    XCTAssertTrue(app.buttons["note-actions"].exists)

    if app.isRegularWidth {
      modes.buttons["Split"].tap()
      try waitUntil("Split") { preview.exists && editor.exists }
    }

    modes.buttons["Edit"].tap()
    try waitUntil("Edit again") { editor.exists && !preview.exists }
    XCTAssertTrue(title.exists)
    XCTAssertTrue(app.buttons["note-actions"].exists)
  }

  func testSwitchingFiles() throws {
    let app = launchGistPad(open: "shape/README.md", mode: "edit")
    let editor = app.textViews["source-editor"]
    try waitUntil("README.md") { editor.exists && app.navigationBars.staticTexts["README.md"].exists }

    app.buttons["note-actions"].tap()
    app.buttons["Files"].firstMatch.tap()
    app.buttons["Ideas.md"].firstMatch.tap()
    try waitUntil("Ideas.md") { (editor.value as? String)?.hasPrefix("# Ideas") == true }
    XCTAssertTrue(app.navigationBars.staticTexts["Ideas.md"].exists)
  }
}
