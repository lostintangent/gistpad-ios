import XCTest

@MainActor
final class CommentsInspectorUITests: XCTestCase {
  func testOpenCommentsKeepsLongPreviewReadingPosition() throws {
    try checkPreviewReadingPosition(
      scenario: "long-reading", passages: ["Reading section 5", "Reading section 6"])
  }

  func testOpenCommentsKeepsAX3PreviewReadingPosition() throws {
    try checkPreviewReadingPosition(
      scenario: "reading-list", passages: ["Reading idea 12:", "Reading idea 14:"],
      accessibility: true)
  }

  private func checkPreviewReadingPosition(
    scenario: String, passages: [String], accessibility: Bool = false
  ) throws {
    let app = launch(scenario: scenario, accessibility: accessibility)
    defer { app.terminate() }
    XCTAssertEqual(app.windows.firstMatch.frame.width, 951, accuracy: 1)
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    try wait("the reading note") { row.isHittable }
    row.tap()
    try wait("the reading Preview") { app.webViews.firstMatch.exists }
    app.buttons["Hide Sidebar"].tap()
    try wait("the complete collapsed reading canvas") {
      !row.isHittable && app.buttons["Show Sidebar"].isHittable
        && abs(app.webViews.firstMatch.frame.minX - app.windows.firstMatch.frame.minX) <= 1
    }
    for (index, prefix) in passages.enumerated() {
      let passage = try revealPreviewPassage(prefix, in: app, maximumScrolls: 24)
      try alignReadingPassage(passage, in: app)
      let originalY = passage.frame.minY
      record(app, name: "comments-reading-\(scenario)-\(index)-before")
      app.buttons["note-comments"].tap()
      try wait("Comments beside the reading Preview") { app.buttons["comments-close"].isHittable }
      try waitForSettledFrame(app.webViews.firstMatch)
      let openedY = passage.frame.minY
      record(app, name: "comments-reading-\(scenario)-\(index)-opened")
      app.buttons["comments-close"].tap()
      try wait("Comments to close without restoring the Library") {
        !app.otherElements["comments-inspector"].firstMatch.exists
          && app.buttons["Show Sidebar"].isHittable && !row.isHittable
      }
      try waitForSettledFrame(app.webViews.firstMatch)
      record(app, name: "comments-reading-\(scenario)-\(index)-closed")
      XCTAssertEqual(openedY, originalY, accuracy: 2, "Opening Comments moved the reading passage.")
      XCTAssertEqual(passage.frame.minY, originalY, accuracy: 2, "Closing Comments moved the reading passage.")
      XCTAssertTrue(app.segmentedControls["note-toggle-mode"].buttons["Preview"].isSelected)
    }
  }

  func testClosedCommentsAtLargeAndAX3InBothAppearances() throws {
    try checkAppearances(wide: false)
  }

  func testOpenCommentsAtLargeAndAX3InBothAppearances() throws {
    try checkAppearances(wide: true)
  }

  func testOpenCloseRestoresThePinnedLibraryColumn() throws {
    let app = launch()
    defer { app.terminate() }
    XCTAssertEqual(app.windows.firstMatch.frame.width, 951, accuracy: 1)
    try openComments(in: app)
    record(app, name: "comments-open-before-close")
    app.buttons["comments-close"].tap()
    try wait("the entire inspector to disappear") {
      !app.otherElements["comments-inspector"].firstMatch.exists
        && !app.buttons["comments-close"].exists
    }
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    try wait("the restored pinned Library column") {
      row.isHittable && row.frame.maxX <= app.webViews.firstMatch.frame.minX + 1
    }
    record(app, name: "comments-open-after-close-pinned-library")
    app.buttons["Hide Sidebar"].tap()
    try wait("the intentionally hidden Library") {
      !row.isHittable && app.buttons["Show Sidebar"].isHittable
    }
    app.buttons["Show Sidebar"].tap()
    try wait("the pinned Library after its native toggle") {
      row.isHittable && row.frame.maxX <= app.webViews.firstMatch.frame.minX + 1
    }
  }

  func testOpenCloseFromPreviewSourceAndReplyRestoresSidebarVisibility() throws {
    for appearance in ["light", "dark"] {
      let app = launch(appearance: appearance)
      defer { app.terminate() }
      XCTAssertEqual(app.windows.firstMatch.frame.width, 951, accuracy: 1)
      try openComments(in: app)
      try closeAndExpectPinnedLibrary(in: app)

      let passage = try revealPreviewPassage("A good walk clears more than your head", in: app)
      passage.tap()
      try waitForSelectedThread(300, in: app)
      try closeAndExpectPinnedLibrary(in: app)

      app.buttons["Edit"].tap()
      let editor = app.textViews["source-editor"]
      try wait("the source editor") { editor.isHittable && app.buttons["Edit"].isSelected }
      app.buttons["Hide Keyboard"].tap()
      try wait("the unfocused source passage") { !app.keyboards.firstMatch.exists }
      record(app, name: "comments-open-source-before-passage-tap")
      editor.coordinate(withNormalizedOffset: .zero)
        .withOffset(.init(
          dx: 60, dy: app.navigationBars["A place for good ideas"].frame.maxY + 77
            - editor.frame.minY)).tap()
      try wait("the source passage's Comments inspector") {
        app.buttons["comments-close"].isHittable
          && app.descendants(matching: .any)["comment-thread-300"].firstMatch.isSelected
      }
      try closeAndExpectPinnedLibrary(in: app, source: true)

      app.buttons["note-comments"].tap()
      try wait("the reopened conversation for a reply") { app.buttons["comment-reply-300"].isHittable }
      app.buttons["comment-reply-300"].tap()
      let field = composer(in: app)
      field.typeText("Keep the conversation open.")
      try wait("the enabled reply") { app.buttons["comment-post"].isEnabled }
      app.buttons["comment-post"].tap()
      try wait("the reply acknowledgement") {
        (field.value as? String)?.contains("Keep the conversation open.") == false
          && app.buttons["note-comments"].label == "Comments, 6 comments"
      }
      try closeAndExpectPinnedLibrary(in: app, source: true)

      app.buttons["Hide Sidebar"].tap()
      let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
      try wait("the deliberately hidden sidebar") { !row.isHittable }
      app.buttons["note-comments"].tap()
      try wait("Comments while the sidebar was hidden") { app.buttons["comments-close"].isHittable }
      let unsent = composer(in: app)
      unsent.tap()
      unsent.typeText("An unsent reply stays on this iPhone.")
      app.buttons["comments-close"].tap()
      try wait("the hidden sidebar to stay hidden after Close") {
        !app.otherElements["comments-inspector"].firstMatch.exists
          && !row.isHittable && app.buttons["Show Sidebar"].isHittable
      }
      record(app, name: "comments-open-close-keeps-hidden-sidebar-\(appearance)")
    }
  }

  func testOpenCloseFromTheLibraryRowAndAfterRefreshRetainsTheDraft() throws {
    let app = launch()
    defer { app.terminate() }
    XCTAssertEqual(app.windows.firstMatch.frame.width, 951, accuracy: 1)
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    try wait("the Library row") { row.isHittable }
    row.press(forDuration: 1)
    app.buttons["Open Comments"].tap()
    try wait("the row's live conversation") { app.buttons["comments-close"].isHittable }
    let field = composer(in: app)
    field.tap()
    field.typeText("Save this without posting.")
    app.buttons["comments-actions"].tap()
    app.buttons["Refresh Comments"].tap()
    try wait("the refreshed thread") { app.buttons["comment-actions-300"].isHittable }
    try closeAndExpectPinnedLibrary(in: app)
    row.press(forDuration: 1)
    app.buttons["Open Comments"].tap()
    try wait("the row to reopen the retained unposted draft") {
      app.buttons["comments-close"].isHittable
        && (composer(in: app).value as? String)?.contains("Save this without posting.") == true
    }
    try closeAndExpectPinnedLibrary(in: app)
  }

  func testOpenSidebarOverlayDoesNotPreventCommentsClose() throws {
    let app = launch()
    defer { app.terminate() }
    try openComments(in: app)
    let window = app.windows.firstMatch
    let edge = window.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: 1, dy: 330))
    edge.press(
      forDuration: 0.05, thenDragTo: edge.withOffset(.init(dx: 300, dy: 0)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
    record(app, name: "comments-open-library-edge-swipe")
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    if !row.isHittable { app.buttons["Show Sidebar"].tap() }
    try wait("the Library overlay while Comments uses the trailing column") { row.isHittable }
    XCTAssertGreaterThan(row.frame.maxX, app.webViews.firstMatch.frame.minX)
    record(app, name: "comments-open-library-overlay")
    try closeAndExpectPinnedLibrary(in: app)
  }

  func testCommentsCloseAcrossSheetAndInspectorPostureTransitions() throws {
    let app = launch()
    defer { app.terminate() }
    XCTAssertEqual(app.windows.firstMatch.frame.width, 466, accuracy: 1)
    try openComments(in: app)
    record(app, name: "comments-transition-ready-to-unfold")
    try wait("the phone to unfold with the Comments sheet open", timeout: 90) {
      abs(app.windows.firstMatch.frame.width - 951) <= 1
    }
    try wait("the first unfolded Comments inspector") {
      app.buttons["comments-close"].isHittable
    }
    record(app, name: "comments-transition-ready-to-fold-before-close")
    try wait("the phone to fold again without closing Comments", timeout: 90) {
      abs(app.windows.firstMatch.frame.width - 466) <= 1
    }
    try wait("the retained Comments sheet") { app.buttons["comments-close"].isHittable }
    record(app, name: "comments-transition-ready-to-unfold-again")
    try wait("the phone to unfold again without closing Comments", timeout: 90) {
      abs(app.windows.firstMatch.frame.width - 951) <= 1
    }
    try wait("the retained Comments inspector") { app.buttons["comments-close"].isHittable }
    try closeAndExpectPinnedLibrary(in: app)
    record(app, name: "comments-transition-unfolded-after-close")
    app.buttons["note-comments"].tap()
    try wait("the reopened unfolded inspector") { app.buttons["comments-close"].isHittable }
    record(app, name: "comments-transition-ready-to-fold")
    try wait("the phone to fold with the inspector open", timeout: 90) {
      abs(app.windows.firstMatch.frame.width - 466) <= 1
    }
    try wait("the folded Comments sheet") { app.buttons["comments-close"].isHittable }
    record(app, name: "comments-transition-folded-before-close")
    app.buttons["comments-close"].tap()
    try wait("the folded inspector to disappear") {
      !app.buttons["comments-close"].exists
        && !app.otherElements["comments-inspector"].firstMatch.exists
        && !app.buttons["note-comments"].isSelected
    }
    record(app, name: "comments-transition-folded-after-close")
  }

  private func closeAndExpectPinnedLibrary(in app: XCUIApplication, source: Bool = false) throws {
    app.buttons["comments-close"].tap()
    let row = app.descendants(matching: .any)["library-note-ideas"].firstMatch
    try wait("Close to remove the inspector and restore a pinned Library column") {
      let document = source ? app.textViews["source-editor"] : app.webViews.firstMatch
      return !app.otherElements["comments-inspector"].firstMatch.exists
        && !app.buttons["comments-close"].exists && !app.buttons["note-comments"].isSelected
        && row.isHittable && row.frame.maxX <= document.frame.minX + 1
    }
    record(app, name: "comments-open-closed-\(source ? "source" : "preview")")
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

  func testPreviewPassageTapsSelectTheirOwnThreadAcrossReopening() throws {
    let app = launch()
    defer { app.terminate() }
    try openComments(in: app)
    app.buttons["comments-close"].tap()
    try wait("the initial inspector dismissal") { !app.buttons["comments-close"].exists }

    for (index, target) in [
      ("Write something useful, then give it room to breathe.", 200),
      ("A good walk clears more than your head", 300),
      ("Write something useful, then give it room to breathe.", 200),
    ].enumerated() {
      let (prefix, id) = target
      let passage = try revealPreviewPassage(prefix, in: app)
      record(app, name: "comments-preview-before-tapping-thread-\(id)")
      passage.tap()
      try waitForSelectedThread(id, in: app)
      record(app, name: "comments-preview-opens-thread-\(id)")
      if index == 0 {
        let next = try revealPreviewPassage("A good walk clears more than your head", in: app)
        next.tap()
        try waitForSelectedThread(300, in: app)
        record(app, name: "comments-preview-switches-thread-without-closing")
      }
      app.buttons["comments-close"].tap()
      try wait("the inspector for thread \(id) to dismiss") {
        !app.buttons["comments-close"].exists && !app.buttons["note-comments"].isSelected
      }
    }
  }

  func testPreviewPassagesSelectReorderedOffscreenThreadsAndResolveOverlaps() throws {
    let app = launch(scenario: "reading-list")
    defer { app.terminate() }
    try openComments(in: app, waitsForConversation: false)
    try wait("the loaded reading-list comments") {
      app.buttons["comment-actions-10017"].exists
    }
    app.buttons["comments-close"].tap()
    try wait("the reading-list inspector dismissal") { !app.buttons["comments-close"].exists }

    for (prefix, id, choice): (String, Int, String?) in [
      ("Reading idea 1:", 10_000, nil),
      ("Reading idea 24:", 10_017, nil),
      ("Reading idea 6", 10_011, "octavia: Reading thought 6."),
      ("Reading idea 6", 20_050, "mira: Another thought about reading idea 6."),
      ("Reading idea 6", 20_051, "mira: A narrower thought about reading idea 6."),
    ] {
      let passage = try revealPreviewPassage(prefix, in: app)
      record(app, name: "comments-reading-list-before-thread-\(id)")
      passage.tap()
      if let choice {
        let action = app.buttons.matching(
          NSPredicate(format: "label BEGINSWITH %@", choice)).firstMatch
        try wait("the exact overlap choice for thread \(id)") { action.isHittable }
        action.tap()
      }
      try waitForSelectedThread(id, in: app)
      record(app, name: "comments-reading-list-opens-thread-\(id)")
      if id == 10_000 {
        for (nextPrefix, nextID) in [
          ("Reading idea 2:", 10_007), ("Reading idea 1:", 10_000),
        ] {
          let next = try revealPreviewPassage(nextPrefix, in: app)
          next.tap()
          try waitForSelectedThread(nextID, in: app)
        }
        let selected = app.descendants(matching: .any)["comment-thread-\(id)"].firstMatch
        let originalY = selected.frame.minY
        app.descendants(matching: .any)["comments-conversation"].firstMatch.swipeDown()
        XCTAssertGreaterThan(selected.frame.minY, originalY + 8, "Manual scrolling must not reanchor.")
        let repeated = try revealPreviewPassage(prefix, in: app)
        repeated.tap()
        try waitForSelectedThread(id, in: app)
        record(app, name: "comments-reading-list-repeats-selected-thread-\(id)")
      }
      app.buttons["comments-close"].tap()
      try wait("the reading-list thread \(id) dismissal") {
        !app.buttons["comments-close"].exists && !app.buttons["note-comments"].isSelected
      }
    }
  }

  func testPreviewSelectedThreadStaysVisibleAcrossRefresh() throws {
    let app = launch(scenario: "reading-list", controlledRefresh: true)
    defer { app.terminate() }
    try openComments(in: app, waitsForConversation: false)
    try wait("the loaded reading-list comments") {
      app.buttons["comment-actions-10017"].exists
    }
    app.buttons["comments-close"].tap()
    try wait("the reading-list inspector dismissal") { !app.buttons["comments-close"].exists }
    let passage = try revealPreviewPassage("Reading idea 6", in: app)
    passage.tap()
    let choice = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "octavia: Reading thought 6.")).firstMatch
    try wait("the exact mid-list overlap choice") { choice.isHittable }
    choice.tap()
    try waitForSelectedThread(10_011, in: app)
    let hold = app.buttons["comments-hold-refresh"]
    try wait("the native fixture refresh control") { hold.isHittable }
    hold.tap()
    try wait("the controlled remote refresh to arm") { hold.value as? String == "Armed" }
    app.buttons["comments-actions"].tap()
    app.buttons["Refresh Comments"].tap()
    try wait("the in-content refreshing status") { app.staticTexts["Updating comments"].exists }
    try waitForSelectedThread(10_011, in: app)
    record(app, name: "comments-selected-thread-during-refresh")
    app.buttons["comments-finish-refresh"].tap()
    try wait("the in-content status to be removed") { !app.staticTexts["Updating comments"].exists }
    try waitForSelectedThread(10_011, in: app)
    record(app, name: "comments-selected-thread-after-refresh")
  }

  func testConversationInteractionDoesNotRestoreTheOldSelection() throws {
    let app = launch(controlledRefresh: true)
    defer { app.terminate() }
    try openComments(in: app)
    app.buttons["comments-close"].tap()
    try wait("the inspector dismissal") { !app.buttons["comments-close"].exists }
    let passage = try revealPreviewPassage(
      "Write something useful, then give it room to breathe.", in: app)
    passage.tap()
    try waitForSelectedThread(200, in: app)
    let conversation = app.descendants(matching: .any)["comments-conversation"].firstMatch
    let selected = app.descendants(matching: .any)["comment-thread-200"].firstMatch
    let selectedY = selected.frame.minY
    try reveal(app.buttons["comment-passage-300"], in: app)
    try wait("manual scrolling away from the selected thread") {
      selected.frame.minY > selectedY + 80
    }
    let replies = app.descendants(matching: .any)["comment-replies-300"].firstMatch
    try reveal(replies, in: app)
    replies.tap()
    try wait("the other thread's replies") {
      app.descendants(matching: .any)["comment-replies-301"].firstMatch.exists
    }
    XCTAssertGreaterThan(selected.frame.minY, app.navigationBars["Comments"].frame.maxY + 44)
    record(app, name: "comments-user-scroll-survives-other-replies")

    try reveal(app.buttons["comment-passage-300"], in: app)
    let isExpanded = app.windows.firstMatch.frame.width > 640
    if isExpanded { conversation.swipeDown() }
    let hold = app.buttons["comments-hold-refresh"]
    hold.tap()
    try wait("the next remote refresh to be held") { hold.value as? String == "Armed" }
    if isExpanded {
      let start = conversation.coordinate(withNormalizedOffset: .zero)
        .withOffset(
          .init(
            dx: conversation.frame.width / 2,
            dy: app.navigationBars["Comments"].frame.maxY + 44 - conversation.frame.minY))
      let end = conversation.coordinate(withNormalizedOffset: .zero)
        .withOffset(
          .init(
            dx: conversation.frame.width / 2,
            dy: app.otherElements["comments-composer"].firstMatch.frame.minY - 24
              - conversation.frame.minY))
      start.press(
        forDuration: 0.05, thenDragTo: end,
        withVelocity: .slow, thenHoldForDuration: 0.2)
    } else {
      app.buttons["comments-actions"].tap()
      app.buttons["Refresh Comments"].tap()
    }
    try wait("refreshing at the user's reading position") {
      app.staticTexts["Updating comments"].exists
    }
    XCTAssertGreaterThan(selected.frame.minY, app.navigationBars["Comments"].frame.maxY + 44)
    app.buttons["comments-finish-refresh"].tap()
    try wait("refresh completion without restoring the selected thread") {
      !app.staticTexts["Updating comments"].exists
        && selected.frame.minY > app.navigationBars["Comments"].frame.maxY + 44
    }
    XCTAssertTrue(app.buttons["comment-passage-300"].isHittable)
    record(app, name: "comments-user-scroll-survives-refresh")
    let reply = app.buttons["comment-reply-300"]
    try reveal(reply, in: app)
    reply.tap()
    try wait("the other thread's reply composer and keyboard") {
      app.staticTexts["Replying to @mira"].exists && app.keyboards.firstMatch.exists
    }
    XCTAssertGreaterThan(selected.frame.minY, app.navigationBars["Comments"].frame.maxY + 44)
    record(app, name: "comments-user-scroll-survives-other-reply-keyboard")
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
        try wait("the loaded blank conversation") {
          app.buttons["comments-close"].exists
            && !app.descendants(matching: .any)["comments-loading"].exists
        }
        XCTAssertFalse(app.staticTexts["No comments yet"].exists)
        XCTAssertTrue(composer(in: app).exists)
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

  func testT166CommentStateCaptures() throws {
    for appearance in ["dark"] {
      let app = launch(scenario: "empty", appearance: appearance, holdsPost: true)
      defer { app.terminate() }
      try openComments(in: app, waitsForConversation: false)
      try wait("the loaded blank conversation") {
        app.buttons["comments-close"].isHittable
          && !app.descendants(matching: .any)["comments-loading"].exists
      }
      XCTAssertFalse(app.staticTexts["No comments yet"].exists)
      record(app, name: "t166-comments-empty-\(appearance)")
      let field = composer(in: app)
      field.tap()
      field.typeText("Looks good to me.")
      try wait("the enabled send button") { app.buttons["comment-post"].isEnabled }
      record(app, name: "t166-comments-composer-text-\(appearance)")
      app.buttons["comment-post"].tap()
      try wait("the posting state") { !app.buttons["comment-post"].isEnabled }
      record(app, name: "t166-comments-posting-\(appearance)")
      try wait("the posted comment") {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Looks good to me.")).firstMatch.exists
          && !app.buttons["comment-post"].isEnabled
      }
      record(app, name: "t166-comments-posted-\(appearance)")
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
    accessibility: Bool = false, increased: Bool = false, controlledRefresh: Bool = false,
    holdsPost: Bool = false
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
    if controlledRefresh { app.launchArguments.append("--capture-controlled-comment-refresh") }
    if holdsPost { app.launchArguments.append("--capture-hold-comment-post") }
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

  private func waitForSelectedThread(_ id: Int, in app: XCUIApplication) throws {
    let thread = app.descendants(matching: .any)["comment-thread-\(id)"].firstMatch
    let passage = app.buttons["comment-passage-\(id)"]
    let anchorsAtTop = [10_011, 20_050, 20_051].contains(id)
    try wait("Preview to select and visibly reveal thread \(id)") {
      app.buttons["comments-close"].exists && thread.exists && thread.isSelected
        && passage.exists && passage.isSelected && passage.isHittable
        && thread.frame.minY >= conversationReadingTop(in: app) - 1
        && (!anchorsAtTop || thread.frame.minY <= conversationReadingTop(in: app) + 8)
        && passage.frame.midY >= conversationReadingTop(in: app)
        && passage.frame.midY <= app.otherElements["comments-composer"].firstMatch.frame.minY
    }
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  private func conversationReadingTop(in app: XCUIApplication) -> CGFloat {
    let navigation = app.navigationBars["Comments"]
    // Compact rail-only chrome retains an empty AX bar above unobscured content.
    if app.windows.firstMatch.frame.width < 600,
      navigation.children(matching: .any).count == 0 {
      return navigation.frame.minY
    }
    return navigation.frame.maxY
  }

  private func revealPreviewPassage(
    _ prefix: String, in app: XCUIApplication, maximumScrolls: Int = 12
  ) throws -> XCUIElement {
    let webView = app.webViews.firstMatch
    let passage = webView.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    let inspector = app.otherElements["comments-inspector"].firstMatch
    let navigation = app.navigationBars["A place for good ideas"]
    func visibleBounds() -> (top: CGFloat, bottom: CGFloat) {
      let top = navigation.frame.maxY + 8
      let bottom = inspector.exists && app.windows.firstMatch.frame.width < 600
        ? inspector.frame.minY - 8 : webView.frame.maxY - 44
      return (top, bottom)
    }
    for scroll in 0...maximumScrolls {
      let (top, bottom) = visibleBounds()
      if passage.exists, passage.isHittable,
        passage.frame.minX >= webView.frame.minX, passage.frame.maxX <= webView.frame.maxX,
        passage.frame.minY >= top, passage.frame.maxY <= bottom { return passage }
      guard scroll < maximumScrolls else { break }
      let center = (top + bottom) / 2
      let step = (bottom - top) * 0.35
      let distance = passage.exists
        ? min(step, max(-step, center - passage.frame.midY)) : -step
      let start = webView.coordinate(withNormalizedOffset: .zero)
        .withOffset(.init(dx: webView.frame.width / 2, dy: center - webView.frame.minY))
      start.press(
        forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: 0, dy: distance)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    record(app, name: "comments-unreachable-preview-passage")
    XCTFail("The Preview passage was not reachable clear of native navigation and the inspector.")
    throw CommentsTestError.timedOut
  }

  private func alignReadingPassage(_ passage: XCUIElement, in app: XCUIApplication) throws {
    let webView = app.webViews.firstMatch
    let top = app.navigationBars["A place for good ideas"].frame.maxY
    let firstLine = top...(top + 16)
    for _ in 0..<4 {
      let original = passage.frame.minY
      if firstLine.contains(original) { return }
      let start = webView.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
      start.press(
        forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: 0, dy: top + 2 - original)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    XCTAssertTrue(firstLine.contains(passage.frame.minY))
  }

  private func waitForSettledFrame(_ element: XCUIElement) throws {
    var previous = CGRect.null
    var stableSince = Date()
    try wait("the settled reading frame") {
      guard element.exists else { return false }
      let frame = element.frame
      guard frame == previous else {
        previous = frame
        stableSince = .now
        return false
      }
      return !frame.isEmpty && Date().timeIntervalSince(stableSince) >= 0.5
    }
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

  private func wait(_ description: String, timeout: TimeInterval = 12, _ ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
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
