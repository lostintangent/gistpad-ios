import XCTest

@MainActor
final class DailyNotesUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testTodayOpensReadyToWrite() throws {
    let app = launchGistPad()
    let today = app.element("library-today")
    try waitUntil("Today") { today.isHittable }
    today.tap()
    let editor = app.textViews["source-editor"]
    try waitUntil("today's note, ready to write") {
      editor.isHittable && app.keyboards.firstMatch.exists
        && (editor.value as? String)?.contains("Morning pages") == true
    }
  }

  func testTodayStartsTheDayInAnEmptyLibrary() throws {
    let app = launchGistPad("empty")
    let today = app.element("library-today")
    try waitUntil("Today") { today.isHittable }
    today.tap()
    let editor = app.textViews["source-editor"]
    try waitUntil("a new day, ready to write") { editor.isHittable && app.keyboards.firstMatch.exists }
    editor.typeText("First thought of the day")
    XCTAssertTrue((editor.value as? String)?.contains("First thought of the day") == true)
  }

  func testAddToTodayAppendsATask() throws {
    let app = launchGistPad(sheet: "today")
    let input = app.textViews["today-capture-input"]
    try waitUntil("Add to Today") { input.isHittable && app.keyboards.firstMatch.exists }
    app.segmentedControls["today-capture-kind"].buttons["Task"].tap()
    input.tap()
    input.typeText("Pick up the dry cleaning")
    app.buttons["today-capture-add"].tap()

    let editor = app.textViews["source-editor"]
    try waitUntil("today's note with the new task") {
      app.noteShows("Pick up the dry cleaning") && !app.textViews["today-capture-input"].exists
    }
    if let source = editor.value as? String {
      XCTAssertTrue(source.contains("- [ ] Pick up the dry cleaning"), source)
    }
  }
}
