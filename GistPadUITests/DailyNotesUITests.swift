import XCTest

@MainActor
final class DailyNotesUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testTodayOpensReadyToWrite() throws {
    let app = launchGistPad()
    let today = app.element("library-today")
    try waitUntil("Today with its unfinished tasks") {
      today.isHittable && today.label == "Today, 2 unfinished tasks"
    }
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

  func testDeletingADailyNoteFromItsScreenKeepsTheOtherDays() throws {
    // The fixture's daily notes gist holds four days, ending today.
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let yesterday = formatter.string(from: .now.addingTimeInterval(-86_400))
    let app = launchGistPad(open: "daily/\(yesterday).md")
    try tap(app.buttons["note-actions"].firstMatch, "More")
    try tap(app.buttons["Delete Daily Note…"].firstMatch, "Delete Daily Note…")
    try waitUntil("a confirmation that names the day") { app.staticTexts["Delete “\(yesterday)”?"].exists }
    try confirmDeletion(in: app)

    // Deleting the open file returns to the Library.
    XCTAssertTrue(app.element("library-list").waitForExistence(timeout: 10))
    let dailyNotes = app.element("library-collection-dailyNotes")
    dailyNotes.scrollIntoView(in: app)
    try waitUntil("the other three days") { dailyNotes.countValue == "3 daily notes" }
  }

  func testAddToTodayAppendsATask() throws {
    let app = launchGistPad(sheet: "today")
    let input = app.textFields["today-capture-input"]
    try waitUntil("Add to Today") { input.isHittable && app.keyboards.firstMatch.exists }
    app.segmentedControls["today-capture-kind"].buttons["Task"].tap()
    input.tap()
    input.typeText("Pick up the dry cleaning")
    app.buttons["today-capture-add"].tap()

    let editor = app.textViews["source-editor"]
    try waitUntil("today's note with the new task") {
      app.noteShows("Pick up the dry cleaning") && !app.textFields["today-capture-input"].exists
    }
    if let source = editor.value as? String {
      XCTAssertTrue(source.contains("- [ ] Pick up the dry cleaning"), source)
    }
  }
}
