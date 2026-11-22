import XCTest

@MainActor
final class CommentsUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testOpeningAndClosingCommentsKeepsThePreviewInPlace() throws {
    let app = launchGistPad(open: "highlights", mode: "preview")
    let late = app.buttons["A late native passage"].firstMatch
    try waitUntil("the Preview") { app.webViews.firstMatch.exists && late.exists }
    // With the sidebar hidden, Comments is the only thing that changes the reading width.
    app.dismissSidebarOverlay()
    let hideSidebar = app.buttons["Hide Sidebar"].firstMatch
    if hideSidebar.isTappable {
      hideSidebar.tap()
      try waitUntil("the hidden sidebar") { app.buttons["Show Sidebar"].firstMatch.isTappable }
    }
    // Slow swipes barely coast, so the passage can't pass the screen between checks.
    for _ in 0..<10 where !late.isTappable { app.webViews.firstMatch.swipeUp(velocity: .slow) }
    try waitUntil("the late passage on screen") { late.isTappable }
    try alignToTop(late, in: app)
    let before = late.frame

    app.element("note-comments").tap()
    let close = app.buttons["comments-close"]
    try waitUntil("Comments") { close.isTappable && app.element("comment-thread-1").exists }
    try waitUntil("the passage on the same line beside Comments") { abs(late.frame.minY - before.minY) <= 8 }
    close.tap()
    try waitUntil("Comments to close") { !close.exists }
    try waitUntil("the passage back where it was") {
      abs(late.frame.minY - before.minY) <= 8 && abs(late.frame.minX - before.minX) <= 8
    }
  }

  func testPostingAndReplying() throws {
    let app = launchGistPad(open: "highlights", mode: "preview", sheet: "comments")
    let composer = app.element("comment-composer-text")
    try waitUntil("Comments") { app.element("comment-thread-1").exists && composer.exists }

    try tap(app.buttons["comment-reply-1"], "Reply")
    try waitUntil("the reply composer") { app.staticTexts["Replying to @octocat"].exists }
    composer.tap()
    composer.typeText("Agreed, keep it.")
    app.buttons["comment-post"].tap()
    // Thread 1 had no replies, so its replies appearing means the reply didn't start a thread.
    try waitUntil("the reply") { app.element("comment-replies-1").exists }
    try scroll(to: "comment-thread-4", in: app)

    composer.tap()
    composer.typeText("A new thought on the whole note.")
    app.buttons["comment-post"].tap()
    // GitHub numbers this gist's comments, so the reply is 5 and the new thread is 6.
    try scroll(to: "comment-thread-6", in: app)
    XCTAssertFalse(app.element("comment-thread-5").exists, "The reply became its own thread.")
  }

  func testOnlyALongQuoteOffersTheFullQuote() throws {
    let app = launchGistPad(open: "highlights", mode: "preview", sheet: "comments")
    try waitUntil("Comments") { app.element("comment-thread-1").exists }
    XCTAssertFalse(app.element("comment-thread-1").buttons["Show Full Quote"].exists)

    // The thread can exist before it's on screen, so swipe until its button is.
    let long = app.element("comment-thread-4")
    let more = long.buttons["Show Full Quote"]
    for _ in 0..<6 where !more.isTappable { app.element("comments-conversation").swipeUp() }
    try tap(more, "Show Full Quote")
    try tap(long.buttons["Show Less"], "Show Less")
    try waitUntil("the quote folded again") { long.buttons["Show Full Quote"].exists }
  }

  func testTappingAHighlightSelectsItsThread() throws {
    let app = launchGistPad(open: "highlights", mode: "preview")
    let careful = app.buttons["careful"].firstMatch
    try waitUntil("the highlight") { careful.isTappable }
    app.dismissSidebarOverlay()
    careful.tap()
    let thread = app.element("comment-thread-2")
    try waitUntil("the selected thread") { thread.exists && thread.isSelected }
  }

  /// Swipes through the conversation until `thread` is on screen. Folded, the sheet fits two
  /// threads, and only threads on screen are in the accessibility tree.
  private func scroll(to thread: String, in app: XCUIApplication) throws {
    let element = app.element(thread)
    let conversation = app.element("comments-conversation")
    for _ in 0..<6 where !element.exists { conversation.swipeUp() }
    try waitUntil(thread) { element.exists }
  }

  /// Drags the Preview until `passage` sits on the first line under the navigation bar.
  /// The Preview anchors its top line through reflow, so that's the line that must hold still.
  private func alignToTop(_ passage: XCUIElement, in app: XCUIApplication) throws {
    let top = app.navigationBars["A gist with comments"].frame.maxY
    let firstLine = top...(top + 16)
    for _ in 0..<6 where !firstLine.contains(passage.frame.minY) {
      // The scroll view spends a drag's first points on touch slop before the page moves.
      let offset = top + 8 - passage.frame.minY
      let start = app.webViews.firstMatch.coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: offset < 0 ? 0.9 : 0.2))
      start.press(
        forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset + (offset < 0 ? -10 : 10))),
        withVelocity: .slow, thenHoldForDuration: 0.3)
      RunLoop.current.run(until: .now.addingTimeInterval(0.5))
    }
    XCTAssertTrue(firstLine.contains(passage.frame.minY), "The passage never reached the top line.")
  }
}
