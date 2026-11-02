import XCTest

@MainActor
final class CommentsUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testOpeningAndClosingCommentsKeepsThePreviewInPlace() throws {
    let app = launchGistPad(open: "highlights", mode: "preview")
    let late = app.buttons["A late native passage"].firstMatch
    try waitUntil("the Preview") { app.webViews.firstMatch.exists && late.exists }
    for _ in 0..<6 where !late.isHittable { app.webViews.firstMatch.swipeUp() }
    try waitUntil("the late passage on screen") { late.isHittable }
    let before = late.frame

    app.element("note-comments").tap()
    let close = app.buttons["comments-close"]
    try waitUntil("Comments") { close.isHittable && app.element("comment-thread-1").exists }
    close.tap()
    try waitUntil("Comments to close") { !close.exists }
    try waitUntil("the passage back where it was") {
      abs(late.frame.minY - before.minY) <= 8 && abs(late.frame.minX - before.minX) <= 8
    }
  }

  func testPostingAndReplying() throws {
    let app = launchGistPad(open: "highlights", mode: "preview", sheet: "comments")
    let threads = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'comment-thread-'"))
    let composer = app.textViews["comment-composer-text"]
    try waitUntil("three threads") { threads.count == 3 && composer.exists }

    composer.tap()
    composer.typeText("A new thought on the whole note.")
    app.buttons["comment-post"].tap()
    try waitUntil("the new thread") { threads.count == 4 }

    let reply = app.buttons["comment-reply-1"]
    for _ in 0..<6 where !reply.isHittable { app.element("comments-conversation").swipeDown() }
    reply.tap()
    composer.tap()
    composer.typeText("Agreed, keep it.")
    app.buttons["comment-post"].tap()
    try waitUntil("the reply") { app.element("comment-replies-1").exists }
    XCTAssertEqual(threads.count, 4)
  }

  func testTappingAHighlightSelectsItsThread() throws {
    let app = launchGistPad(open: "highlights", mode: "preview")
    let careful = app.buttons["careful"].firstMatch
    try waitUntil("the highlight") { careful.isHittable }
    careful.tap()
    let thread = app.element("comment-thread-2")
    try waitUntil("the selected thread") { thread.exists && thread.isSelected }
  }
}
