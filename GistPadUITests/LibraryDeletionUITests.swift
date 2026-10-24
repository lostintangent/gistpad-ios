import XCTest

final class LibraryDeletionUITests: XCTestCase {
  @MainActor
  func testOwnedGistMenuAndConfirmationInLight() async throws {
    try await checkMenuAndConfirmation(dark: false)
  }

  @MainActor
  func testOwnedGistMenuAndConfirmationInDark() async throws {
    try await checkMenuAndConfirmation(dark: true)
  }

  @MainActor
  func testCancellingASwipeKeepsTheSameRowInPlaceInLight() async throws {
    try await checkCancellingSwipe(dark: false)
  }

  @MainActor
  func testCancellingASwipeKeepsTheSameRowInPlaceInDark() async throws {
    try await checkCancellingSwipe(dark: true)
  }

  @MainActor
  private func checkCancellingSwipe(dark: Bool) async throws {
    let app = launch(dark: dark)
    defer { app.terminate() }
    let row = app.descendants(matching: .any)["library-note-b"].firstMatch
    try await waitUntil("the owned gist row") { row.isHittable }
    let frame = row.frame
    row.swipeLeft()
    let delete = app.buttons["Delete"]
    try await waitUntil("the red trailing Delete action") { delete.isHittable }
    record(app, name: "library-delete-swipe-\(dark ? "Dark" : "Light")")
    delete.tap()
    let confirmation = app.buttons["Delete from GitHub"]
    try await waitUntil("the existing GitHub confirmation") { confirmation.isHittable }
    XCTAssertTrue(row.exists)
    let cancel = app.buttons["Cancel"]
    if cancel.exists {
      cancel.tap()
    } else {
      let dismiss = app.otherElements["PopoverDismissRegion"]
      try await waitUntil("the native confirmation dismiss region") { dismiss.isHittable }
      dismiss.tap()
    }
    try await waitUntil("the same closed row after cancellation") {
      row.isHittable && !confirmation.exists && !delete.isHittable
    }
    XCTAssertEqual(row.frame.minX, frame.minX, accuracy: 1)
    XCTAssertEqual(row.frame.minY, frame.minY, accuracy: 1)
    XCTAssertEqual(row.frame.width, frame.width, accuracy: 1)
    XCTAssertEqual(row.frame.height, frame.height, accuracy: 1)
    XCTAssertTrue(app.descendants(matching: .any)["library-note-a"].firstMatch.exists)
    record(app, name: "library-delete-swipe-cancelled-\(dark ? "Dark" : "Light")")
  }

  @MainActor
  private func checkMenuAndConfirmation(dark: Bool) async throws {
    let app = launch(dark: dark)
    defer { app.terminate() }
    let row = app.descendants(matching: .any)["library-note-b"].firstMatch
    try await waitUntil("the owned gist row") { row.isHittable }
    row.press(forDuration: 0.8)
    let delete = app.buttons["Delete"]
    try await waitUntil("the owned gist context menu") { delete.isHittable }
    XCTAssertTrue(app.buttons["Pin"].exists)
    XCTAssertTrue(app.buttons["Archive"].exists)
    record(app, name: "library-delete-menu-\(dark ? "Dark" : "Light")")
    delete.tap()
    let confirmation = app.buttons["Delete from GitHub"]
    try await waitUntil("the existing GitHub deletion confirmation") { confirmation.isHittable }
    XCTAssertTrue(app.staticTexts["Delete “A finished thought” from GitHub?"].exists)
    XCTAssertTrue(row.exists)
    record(app, name: "library-delete-confirmation-\(dark ? "Dark" : "Light")")
    confirmation.tap()
    try await waitUntil("the successfully deleted synthetic gist to leave") { !row.exists }
    XCTAssertTrue(app.descendants(matching: .any)["library-note-a"].firstMatch.exists)
  }

  @MainActor
  private func launch(dark: Bool) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", "library-delete",
      "--capture-appearance", dark ? "dark" : "light",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
    ]
    app.launch()
    return app
  }

  @MainActor
  private func waitUntil(
    _ description: String, file: StaticString = #filePath, line: UInt = #line,
    _ ready: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Timed out waiting for \(description).", file: file, line: line)
    throw DeletionTestError.timedOut
  }

  @MainActor
  private func record(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = "\(name)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}

private enum DeletionTestError: Error { case timedOut }
