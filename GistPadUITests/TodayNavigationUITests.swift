import XCTest

@MainActor
final class TodayNavigationUITests: XCTestCase {
  func testOpenTodayCreatesOrReopensDirectlyAndColdLaunchStaysQuiet() throws {
    try checkToday(wide: true)
  }

  func testClosedTodayCardCreatesTheNoteDirectly() throws {
    try checkToday(wide: false, scenarios: ["missing"])
  }

  private func checkToday(
    wide: Bool, scenarios: [String] = ["missing", "existing", "cold", "signed-out", "retry"]
  ) throws {
    continueAfterFailure = false
    for appearance in ["light", "dark"] {
      for scenario in scenarios {
        let app = XCUIApplication()
        app.launchArguments = [
          "--capture-screen", "today", "--today-fixture", scenario,
          "--capture-appearance", appearance,
          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
          "-dev.gistpad.workspace.note-mode", "reading",
          "-dev.gistpad.workspace.compact-note-mode", "reading",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertEqual(app.windows.firstMatch.frame.width, wide ? 951 : 466, accuracy: 1)
        if scenario == "signed-out" {
          try wait("the existing sign-in path") {
            app.buttons["library-sign-in"].isHittable
          }
          XCTAssertFalse(app.textViews["source-editor"].exists)
          XCTAssertFalse(app.buttons["today-start"].exists)
          record(app, name: "today-\(wide ? "Open" : "Closed")-\(appearance)-signed-out")
          continue
        }
        if scenario == "missing" || scenario == "existing" {
          try wait("the restored ordinary note") { app.webViews.firstMatch.exists }
          if !wide {
            app.buttons["BackButton"].tap()
          }
          let today = app.descendants(matching: .any)["library-today"].firstMatch
          try wait("the native Today destination") { today.isHittable }
          today.tap()
        } else if scenario == "retry" {
          try wait("Today failure with Retry") { app.buttons["note-open-retry"].isHittable }
          record(app, name: "today-Open-\(appearance)-failed")
          app.buttons["note-open-retry"].tap()
        }
        let editor = app.textViews["source-editor"]
        if scenario == "missing" || scenario == "existing" {
          try wait("Today's real editor and intentional keyboard") {
            editor.isHittable && app.keyboards.firstMatch.exists
          }
          try waitForSettledFrame(app.keyboards.firstMatch, description: "Today's keyboard")
          let text = try XCTUnwrap(editor.value as? String)
          if scenario == "existing" {
            XCTAssertTrue(text.contains("An existing daily thought."))
          } else {
            let date = DateFormatter()
            date.calendar = Calendar(identifier: .gregorian)
            date.locale = Locale(identifier: "en_US_POSIX")
            date.dateFormat = "yyyy-MM-dd"
            XCTAssertTrue(text.contains(date.string(from: .now)))
          }
        } else {
          try wait("quiet automatic Today source") { editor.isHittable }
          XCTAssertFalse(app.keyboards.firstMatch.exists)
          XCTAssertFalse(app.activityIndicators["github-status-checking"].exists)
          XCTAssertFalse(app.buttons["github-status-attention"].exists)
        }
        XCTAssertFalse(app.buttons["today-start"].exists)
        record(app, name: "today-\(wide ? "Open" : "Closed")-\(appearance)-\(scenario)")
        if wide, scenario == "cold" {
          let today = app.descendants(matching: .any)["library-today"].firstMatch
          XCTAssertTrue(today.isSelected)
          today.tap()
          try wait("reselecting quiet Today to request editing") {
            editor.isHittable && app.keyboards.firstMatch.exists
          }
          try waitForSettledFrame(app.keyboards.firstMatch, description: "Today's requested keyboard")
          record(app, name: "today-Open-\(appearance)-cold-selected-again")
        }
        if scenario == "missing" || scenario == "existing" {
          editor.typeText(" One captured thought.")
          XCTAssertTrue((editor.value as? String)?.contains("One captured thought.") == true)
          if !wide {
            app.buttons["BackButton"].tap()
            let today = app.descendants(matching: .any)["library-today"].firstMatch
            try wait("the actual Library after Back") {
              today.isHittable && app.navigationBars["GistPad"].exists
                && !app.keyboards.firstMatch.exists
            }
            try waitForSettledFrame(today, description: "the restored Library")
            record(app, name: "today-Closed-\(appearance)-back")
          }
        }
      }
    }
  }

  private func waitForSettledFrame(_ element: XCUIElement, description: String) throws {
    var previous = CGRect.null
    var stableSince = Date()
    try wait("settled \(description)") {
      guard element.exists else { return false }
      let frame = element.frame
      guard frame == previous else {
        previous = frame
        stableSince = .now
        return false
      }
      return !frame.isEmpty && Date().timeIntervalSince(stableSince) >= 1
    }
  }

  private func wait(_ description: String, _ ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if ready() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    record(XCUIApplication(), name: "today-timeout")
    XCTFail("Timed out waiting for \(description).")
    throw TodayTestError.timedOut
  }

  private func record(_ app: XCUIApplication, name: String) {
    let frame = XCTAttachment(screenshot: app.screenshot())
    frame.name = name
    frame.lifetime = .keepAlways
    add(frame)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }

  private enum TodayTestError: Error { case timedOut }
}
