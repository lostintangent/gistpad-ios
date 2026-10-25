import XCTest

@MainActor
final class NoteCommentsBadgeUITests: XCTestCase {
  func testClosedBadgeReceivesItsCountAfterTheToolbarAppears() throws {
    try checkLateCount(wide: false)
  }

  func testOpenBadgeReceivesItsCountAfterTheToolbarAppears() throws {
    try checkLateCount(wide: true)
  }

  private func checkLateCount(wide: Bool) throws {
    continueAfterFailure = false
    for appearance in ["light", "dark"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "--capture-screen", "comments-inspector", "--comments-fixture", "late-count",
        "--capture-appearance", appearance,
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        "-dev.gistpad.workspace.note-mode", "reading",
        "-dev.gistpad.workspace.compact-note-mode", "reading",
      ]
      app.launch()
      defer { app.terminate() }
      XCTAssertEqual(app.windows.firstMatch.frame.width, wide ? 951 : 466, accuracy: 1)
      let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
      try wait("the real notebook row") { row.isHittable }
      row.tap()
      let button = app.buttons["note-comments"]
      try wait("Comments without a premature count") {
        button.isHittable && button.label == "Comments"
      }
      let initialFrame = button.frame
      button.tap()
      try wait("the live conversation's late total") {
        app.buttons["comments-close"].isHittable && app.buttons["comment-actions-300"].exists
      }
      app.buttons["comments-close"].tap()
      try wait("the neutral late count on the same toolbar action") {
        !app.buttons["comments-close"].exists && button.isHittable
          && button.label == "Comments, 5 comments"
      }
      XCTAssertEqual(button.frame, initialFrame)
      XCTAssertFalse(button.isSelected)
      let frame = XCTAttachment(screenshot: app.screenshot())
      frame.name = "comments-late-badge-\(wide ? "Open" : "Closed")-\(appearance)"
      frame.lifetime = .keepAlways
      add(frame)
      let tree = XCTAttachment(string: app.debugDescription)
      tree.name = "comments-late-badge-\(wide ? "Open" : "Closed")-\(appearance)-accessibility"
      tree.lifetime = .keepAlways
      add(tree)
      button.tap()
      try wait("the selected Comments action after the late update") {
        app.buttons["comments-close"].isHittable && button.isSelected
      }
    }
  }

  private func wait(_ description: String, _ ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if ready() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let app = XCUIApplication()
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "comments-badge-timeout-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    XCTFail("Timed out waiting for \(description).")
    throw BadgeTestError.timedOut
  }

  private enum BadgeTestError: Error { case timedOut }
}
