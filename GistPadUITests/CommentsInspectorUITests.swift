import XCTest

@MainActor
final class CommentsInspectorUITests: XCTestCase {
  func testClosedCommentsAtLargeAndAX3InBothAppearances() throws {
    try checkAppearances(wide: false)
  }

  func testOpenCommentsAtLargeAndAX3InBothAppearances() throws {
    try checkAppearances(wide: true)
  }

  func testPostingAndAnUncertainReceiptNeverPostTwice() throws {
    for scenario in ["threads", "uncertain"] {
      let app = launch(scenario: scenario)
      defer { app.terminate() }
      try openComments(in: app)
      let field = composer(in: app)
      field.tap()
      field.typeText("A thought worth keeping")
      let send = app.buttons["comment-post"]
      try wait("the validated explicit Post action") { send.isEnabled && send.isHittable }
      send.tap()
      try wait("the acknowledged comment draft") {
        (field.value as? String)?.contains("A thought worth keeping") == false
      }
      XCTAssertFalse((field.value as? String)?.contains("A thought worth keeping") == true)
      record(app, name: "comments-\(scenario)-acknowledged")
      app.buttons["comments-close"].tap()
      try wait("the dismissed inspector") { !app.buttons["comments-close"].exists }
      XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 6 comments")
      app.buttons["note-comments"].tap()
      try wait("the reopened conversation") { app.buttons["comments-close"].isHittable }
      XCTAssertFalse(app.keyboards.firstMatch.exists)
      XCTAssertEqual(
        app.staticTexts.matching(NSPredicate(format: "label == %@", "A thought worth keeping")).count, 1)
      XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 6 comments")
      app.buttons["comments-close"].tap()
      try wait("the unchanged note after Close") { !app.buttons["comments-close"].exists }
      let back = app.buttons["BackButton"]
      if back.exists, back.isHittable { back.tap() }
      let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
      try wait("the updated gist-wide row total") { row.label.contains("6 comments") }
    }
  }

  func testRepliesAndPermissionAwareMenusUseTheLiveConversation() throws {
    let app = launch()
    defer { app.terminate() }
    try openComments(in: app)
    let more = app.buttons["comment-actions-300"]
    try reveal(more, in: app)
    more.tap()
    XCTAssertTrue(app.buttons["Delete Comment…"].waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["Edit Comment"].exists)
    record(app, name: "comments-owner-permissions")
    app.navigationBars["Comments"].coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
    let reply = app.buttons["comment-reply-300"]
    try reveal(reply, in: app)
    reply.tap()
    try wait("the explicit reply destination") { app.staticTexts["Replying to @mira"].exists }
    let field = composer(in: app)
    field.typeText("I followed the thread.")
    let send = app.buttons["comment-post"]
    try wait("the enabled reply action") { send.isEnabled && send.isHittable }
    send.tap()
    try wait("the reply receipt") {
      (field.value as? String)?.contains("I followed the thread.") == false
    }
    app.buttons["comments-close"].tap()
    try wait("the dismissed reply composer") { !app.buttons["comments-close"].exists }
    XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 6 comments")
    app.buttons["note-comments"].tap()
    let replies = app.descendants(matching: .any)["comment-replies-300"].firstMatch
    try reveal(replies, in: app)
    replies.tap()
    let nested = app.descendants(matching: .any)["comment-replies-301"].firstMatch
    try reveal(nested, in: app)
    record(app, name: "comments-first-reply-expanded")
    nested.tap()
    record(app, name: "comments-nested-reply-expanded")
    try reveal(app.staticTexts["And I’ll bring a question."], in: app, requiresHitTesting: false)
    XCTAssertFalse(app.buttons["comment-reply-302"].exists)
    record(app, name: "comments-two-level-replies")
  }

  func testRejectedPostRetainsTheExactDraft() throws {
    let app = launch(scenario: "rejected")
    defer { app.terminate() }
    try openComments(in: app)
    let field = composer(in: app)
    field.tap()
    field.typeText("Keep these words")
    let send = app.buttons["comment-post"]
    try wait("the enabled Post action") { send.isEnabled }
    send.tap()
    let problem = app.staticTexts["comment-post-error"]
    try wait("the explicit rejection") { problem.exists }
    XCTAssertTrue((field.value as? String)?.contains("Keep these words") == true)
    record(app, name: "comments-rejected-draft-retained")
    app.buttons["comments-close"].tap()
    try wait("the retained rejected draft to close") { !app.buttons["comments-close"].exists }
    XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 5 comments")
  }

  func testEditingAndDeletingPreserveTheQuoteAndDescendants() throws {
    let app = launch()
    defer { app.terminate() }
    try openComments(in: app)
    let ownMenu = app.buttons["comment-actions-200"]
    try reveal(ownMenu, in: app)
    ownMenu.tap()
    app.buttons["Edit Comment"].tap()
    try wait("the authored edit context") { app.staticTexts["Editing your comment"].exists }
    let field = composer(in: app)
    field.typeText(" Still worth keeping.")
    app.buttons["comment-post"].tap()
    let edited = app.staticTexts[
      "Leave this thought open for a little longer. Still worth keeping."]
    try reveal(edited, in: app, requiresHitTesting: false)
    app.buttons["comments-close"].tap()
    try wait("the completed edit to close") { !app.buttons["comments-close"].exists }
    XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 5 comments")
    app.buttons["note-comments"].tap()
    try reveal(app.buttons["comment-passage-200"], in: app)
    record(app, name: "comments-edit-keeps-quote")

    let parentMenu = app.buttons["comment-actions-300"]
    try reveal(parentMenu, in: app)
    parentMenu.tap()
    app.buttons["Delete Comment…"].tap()
    let confirm = app.buttons["Delete Comment"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 4))
    confirm.tap()
    app.buttons["comments-close"].tap()
    try wait("the deleted parent conversation to close") { !app.buttons["comments-close"].exists }
    try wait("the deleted parent receipt") {
      app.buttons["note-comments"].label == "Comments, 4 comments"
    }
    app.buttons["note-comments"].tap()
    try reveal(
      app.staticTexts["I’ll bring the notebook."], in: app, requiresHitTesting: false)
    let replies = app.buttons["comment-replies-301"]
    try reveal(replies, in: app)
    replies.tap()
    try reveal(
      app.staticTexts["And I’ll bring a question."], in: app, requiresHitTesting: false)
    XCTAssertFalse(app.buttons["comment-actions-300"].exists)
    record(app, name: "comments-delete-keeps-descendants")
  }

  func testVerifiedPassageAndPreviewSelectionUseTheLiveInspector() throws {
    let app = launch()
    defer { app.terminate() }
    try openComments(in: app)
    let passage = app.buttons["comment-passage-300"]
    try wait("the verified visible passage") { passage.exists }
    try reveal(passage, in: app)
    passage.tap()
    try reveal(passage, in: app)
    passage.tap()
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    record(app, name: "comments-repeat-verified-passage")
    app.buttons["comments-close"].tap()
    try wait("the closed inspector") { !app.buttons["comments-close"].exists }

    let quote = app.buttons["A good walk clears more than your head"].firstMatch
    try wait("the native preview quote target") { quote.isHittable }
    quote.press(forDuration: 1)
    let add = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Add Comment")).firstMatch
    for _ in 0..<4 {
      if add.waitForExistence(timeout: 1) { break }
      let next = app.buttons["Next Page"].firstMatch
      guard next.exists, next.isHittable else { break }
      next.tap()
    }
    XCTAssertTrue(add.isHittable)
    add.tap()
    let context = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Selected from README.md:")).firstMatch
    try wait("the captured filename and exact native quote") { context.exists }
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    let field = composer(in: app)
    field.typeText("A quoted thought")
    app.buttons["comments-close"].tap()
    try wait("the unposted quoted draft to close") { !app.buttons["comments-close"].exists }
    XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 5 comments")
    app.buttons["note-comments"].tap()
    try wait("the restored quoted draft") {
      (composer(in: app).value as? String)?.contains("A quoted thought") == true && context.exists
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    record(app, name: "comments-native-preview-selection-restored")
  }

  func testFailedDraftSaveKeepsCloseOpenUntilRetry() throws {
    let app = launch(scenario: "draft-failure")
    defer { app.terminate() }
    try openComments(in: app)
    let field = composer(in: app)
    field.tap()
    field.typeText("An unfinished thought")
    let problem = app.descendants(matching: .any)["comment-draft-error"].firstMatch
    try wait("the local draft failure") { problem.exists }
    app.buttons["comments-close"].tap()
    try wait("the failed Close to retain the inspector") {
      app.buttons["comments-close"].isHittable && problem.exists
    }
    XCTAssertTrue((field.value as? String)?.contains("An unfinished thought") == true)
    let retry = app.buttons["Save Draft Again"]
    XCTAssertTrue(retry.isHittable)
    record(app, name: "comments-draft-failure-reachable")
    retry.tap()
    try wait("the confirmed draft retry") { !problem.exists }
    app.buttons["comments-close"].tap()
    try wait("the durable Close") { !app.buttons["comments-close"].exists }
    app.buttons["note-comments"].tap()
    try wait("the restored scoped draft") {
      (composer(in: app).value as? String)?.contains("An unfinished thought") == true
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  func testAX3DraftRecoveryStaysAboveTheKeyboard() throws {
    let app = launch(scenario: "draft-failure", accessibility: true)
    defer { app.terminate() }
    try openComments(in: app)
    let field = composer(in: app)
    field.tap()
    field.typeText("Keep this thought")
    let problem = app.otherElements["comment-draft-error"].firstMatch
    try wait("the accessibility-sized draft failure") { problem.exists }
    let retry = app.buttons["Save Draft Again"]
    let keyboard = app.keyboards.firstMatch
    try wait("the native composer keyboard") { keyboard.exists }
    record(app, name: "comments-AX3-keyboard-draft-failure")
    let top = app.navigationBars["Comments"].frame.maxY
    for control in [field, retry, app.buttons["comment-post"]] {
      XCTAssertGreaterThanOrEqual(control.frame.minY, top)
      XCTAssertLessThanOrEqual(control.frame.maxY, keyboard.frame.minY)
      XCTAssertTrue(control.isHittable)
    }
    app.buttons["comments-close"].tap()
    try wait("the failed accessibility-sized Close") {
      app.buttons["comments-close"].isHittable && problem.exists
    }
    retry.tap()
    try wait("the explicit accessibility-sized retry") { !problem.exists }
    app.buttons["comments-close"].tap()
    try wait("the saved accessibility-sized dismissal") { !app.buttons["comments-close"].exists }
  }

  func testEmptyAndUnavailableCommentsAreNotConfused() throws {
    for scenario in ["empty", "offline", "store-unavailable"] {
      let app = launch(scenario: scenario)
      defer { app.terminate() }
      try openComments(in: app, waitsForConversation: false)
      if scenario == "empty" {
        XCTAssertTrue(app.staticTexts["No comments yet"].waitForExistence(timeout: 6))
        record(app, name: "comments-empty-count")
        XCTAssertEqual(app.buttons["note-comments"].label, "Comments, 0 comments")
      } else if scenario == "offline" {
        XCTAssertTrue(app.staticTexts["Comments couldn’t be loaded"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["No comments yet"].exists)
      } else {
        XCTAssertTrue(app.staticTexts["Comments couldn’t be opened"].waitForExistence(timeout: 6))
        XCTAssertFalse(composer(in: app).exists)
        app.buttons["Close"].tap()
        try wait("the safe opening-error dismissal") {
          !app.staticTexts["Comments couldn’t be opened"].exists
        }
      }
      record(app, name: "comments-\(scenario)")
    }
  }

  private func checkAppearances(wide: Bool) throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        for increased in [false, true] {
          let app = launch(
            appearance: appearance, accessibility: accessibility, increased: increased)
          defer { app.terminate() }
          let window = app.windows.firstMatch.frame
          XCTAssertEqual(window.width, wide ? 951 : 466, accuracy: 1)
          XCTAssertEqual(window.height, wide ? 669 : 678, accuracy: 1)
          let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
          try wait("the comment count in the native row") { row.label.contains("5 comments") }
          let name = "\(wide ? "open" : "closed")-\(appearance)-\(accessibility ? "AX3" : "Large")-\(increased ? "increased" : "normal")"
          record(app, name: "comments-library-\(name)")
          try openComments(in: app)
          let passage = app.buttons["comment-passage-300"]
          try wait("the verified passage action") { passage.isHittable }
          passage.tap()
          let selectedThread = app.descendants(matching: .any)["comment-thread-300"].firstMatch
          try wait("the selected native thread") { selectedThread.isSelected }
          XCTAssertFalse(app.keyboards.firstMatch.exists)
          XCTAssertTrue(app.buttons["note-comments"].isSelected)
          if wide {
            XCTAssertFalse(row.isHittable)
            XCTAssertGreaterThanOrEqual(app.webViews.firstMatch.frame.width, 320)
          } else if accessibility {
            try wait("the accessibility inspector's large presentation") {
              app.navigationBars["Comments"].frame.minY <= window.minY + 80
            }
          }
          record(app, name: "comments-inspector-\(name)")
          app.buttons["comments-close"].tap()
          try wait("Close to restore the original document layout") {
            !app.buttons["comments-close"].exists && !app.buttons["note-comments"].isSelected
          }
          if wide { try wait("the restored native Library column") { row.isHittable } }
        }
      }
    }
  }

  private func launch(
    scenario: String = "threads", appearance: String = "light",
    accessibility: Bool = false, increased: Bool = false
  ) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--capture-screen", "comments-inspector", "--comments-fixture", scenario,
      "--capture-appearance", appearance,
      "-UIPreferredContentSizeCategoryName",
      accessibility ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL",
      "-dev.gistpad.workspace.note-mode", "reading",
      "-dev.gistpad.workspace.compact-note-mode", "reading",
    ]
    if increased { app.launchArguments.append("--capture-increased-contrast") }
    app.launch()
    return app
  }

  private func openComments(in app: XCUIApplication, waitsForConversation: Bool = true) throws {
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    try wait("the real notebook row") { row.isHittable }
    row.tap()
    let toggle = app.buttons["note-comments"]
    try wait("the native Comments toolbar item") { toggle.isHittable }
    let paragraph = app.webViews.firstMatch.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Keep the useful things close.")).firstMatch
    try wait("the rendered native document") { paragraph.exists }
    record(app, name: "comments-note-before-inspector")
    toggle.tap()
    if waitsForConversation {
      try wait("the live Comments inspector") { app.buttons["comments-close"].isHittable }
      try wait("the loaded conversation") { app.buttons["comment-actions-300"].exists }
    }
  }

  private func composer(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["comment-composer-text"].firstMatch
  }

  private func reveal(
    _ element: XCUIElement, in app: XCUIApplication, requiresHitTesting: Bool = true
  ) throws {
    let list = app.descendants(matching: .any)["comments-conversation"].firstMatch
    let composer = app.otherElements["comments-composer"].firstMatch
    for _ in 0..<8 {
      let top = app.navigationBars["Comments"].frame.maxY
      let bottom = composer.exists ? composer.frame.minY : list.frame.maxY
      let center = (top + bottom) / 2
      let step = (bottom - top) * 0.35
      var distance = -step
      if element.exists {
        let frame = element.frame
        if (!requiresHitTesting || element.isHittable),
          frame.minY >= top, frame.maxY <= bottom { return }
        distance = min(step, max(-step, center - frame.midY))
      }
      let start = list.coordinate(withNormalizedOffset: .zero)
        .withOffset(.init(dx: list.frame.width / 2, dy: center - list.frame.minY))
      start.press(
        forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: 0, dy: distance)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    record(app, name: "comments-unreachable-control")
    XCTFail("The comment control was not reachable between the native navigation bar and composer.")
    throw CommentsTestError.timedOut
  }

  private func wait(_ description: String, _ ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if ready() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    record(XCUIApplication(), name: "comments-timeout-\(description)")
    XCTFail("Timed out waiting for \(description).")
    throw CommentsTestError.timedOut
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

  private enum CommentsTestError: Error { case timedOut }
}
