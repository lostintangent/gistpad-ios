import XCTest

final class LibraryDeletionUITests: XCTestCase {
  @MainActor
  func testLocalCopiesOfferDeleteWithoutRemoteActionsInBothAppearances() async throws {
    for dark in [false, true] {
      let app = launch(dark: dark, localCopies: true)
      defer { app.terminate() }
      let title = app.staticTexts["A local copy"].firstMatch
      try await waitUntil("the orphaned local copy") { title.isHittable }
      title.press(forDuration: 0.8)
      try await waitUntil("the local copy context menu") { app.buttons["Delete"].isHittable }
      XCTAssertFalse(app.buttons["Archive"].exists)
      XCTAssertFalse(app.buttons["Pin"].exists)
      record(app, name: "local-copy-menu-\(dark ? "Dark" : "Light")")
      app.buttons["Delete"].tap()
      let confirmation = app.buttons["Delete"].firstMatch
      try await waitUntil("the local-only deletion confirmation") { confirmation.isHittable }
      record(app, name: "local-copy-confirmation-\(dark ? "Dark" : "Light")")
      let cancel = app.buttons["Cancel"]
      if cancel.exists { cancel.tap() }
      else { app.otherElements["PopoverDismissRegion"].tap() }
      try await waitUntil("the local copy after cancellation") { title.isHittable }
      title.swipeLeft()
      try await waitUntil("Delete as the local copy's only trailing action") {
        app.buttons["Delete"].isHittable
      }
      XCTAssertFalse(app.buttons["Archive"].exists)
      try await Task.sleep(for: .milliseconds(450))
      record(app, name: "local-copy-swipe-\(dark ? "Dark" : "Light")")
      app.buttons["Delete"].tap()
      try await waitUntil("the local-only swipe confirmation") { confirmation.isHittable }
      confirmation.tap()
      try await waitUntil("the deleted local copy to leave") { !title.exists }
      XCTAssertTrue(app.staticTexts["A thought to keep"].exists)
    }
  }

  @MainActor
  func testLocalCopyNoteMenuUsesTheSameLocalOnlyConfirmation() async throws {
    let app = launch(dark: true, localCopies: true)
    defer { app.terminate() }
    let title = app.staticTexts["A local copy"].firstMatch
    try await waitUntil("the local copy") { title.isHittable }
    title.tap()
    let actions = app.buttons["note-actions"]
    try await waitUntil("the local copy's recovery explanation or note menu") {
      app.alerts.buttons["OK"].isHittable || actions.isHittable
    }
    if app.alerts.buttons["OK"].isHittable { app.alerts.buttons["OK"].tap() }
    try await waitUntil("the recovery note's menu") { actions.isHittable }
    actions.tap()
    let delete = app.buttons["Delete Note…"]
    try await waitUntil("the local copy's note Delete") { delete.isHittable }
    XCTAssertFalse(app.buttons["Archive"].exists)
    XCTAssertFalse(app.buttons["Pin"].exists)
    delete.tap()
    let confirmation = app.buttons["Delete"].firstMatch
    try await waitUntil("the local-only note confirmation") { confirmation.isHittable }
    record(app, name: "local-copy-note-confirmation")
  }

  @MainActor
  func testANewlyPublishedNoteImmediatelyOffersSwipeDelete() async throws {
    let app = launch(dark: true)
    defer { app.terminate() }
    let create = app.buttons["library-create"]
    try await waitUntil("the Library New Note button") { create.isHittable }
    create.tap()
    let editor = app.textViews["source-editor"]
    try await waitUntil("the new note's retained source editor") { editor.isHittable }
    editor.typeText("A freshly published thought")
    if app.buttons["Hide Keyboard"].isHittable { app.buttons["Hide Keyboard"].tap() }
    let save = app.buttons["note-save"]
    try await waitUntil("the explicit Publish action") { save.isHittable && save.isEnabled }
    save.tap()
    try await waitUntil("the newly published row") {
      app.descendants(matching: .any)["library-note-newcapture"].firstMatch.exists
        || app.buttons["note-comments"].exists
    }
    if app.buttons["BackButton"].isHittable { app.buttons["BackButton"].tap() }
    let row = app.descendants(matching: .any)["library-note-newcapture"].firstMatch
    try await waitUntil("the published Library row without a full refresh") { row.isHittable }
    row.swipeLeft()
    try await waitUntil("Delete on the just-published note") { app.buttons["Delete"].isHittable }
    try await Task.sleep(for: .milliseconds(450))
    record(app, name: "newly-published-swipe-delete")
    app.buttons["Delete"].tap()
    try await waitUntil("the just-published note's deletion confirmation") {
      app.buttons["Delete"].firstMatch.isHittable
    }
  }

  @MainActor
  func testANewlyAutosavedNoteOffersContextMenuAndSwipeDeleteWithoutRefresh() async throws {
    for contextMenu in [false, true] {
      try await checkAutomaticPublicationDeletion(leaving: false, contextMenu: contextMenu)
    }
  }

  @MainActor
  func testLeavingANewNoteOffersContextMenuAndSwipeDeleteWithoutRefresh() async throws {
    for contextMenu in [false, true] {
      try await checkAutomaticPublicationDeletion(leaving: true, contextMenu: contextMenu)
    }
  }

  @MainActor
  func testDeletingANoteWhileItsLeavingPublicationIsInFlightLeavesNothingBehind() async throws {
    let app = launch(dark: false, publicationHold: true)
    defer { app.terminate() }
    let create = app.buttons["library-create"]
    try await waitUntil("the New Note button") { create.isHittable }
    create.tap()
    let editor = app.textViews["source-editor"]
    try await waitUntil("the new note's editor") { editor.isHittable }
    editor.typeText("Parked thought")
    if app.buttons["Hide Keyboard"].isHittable { app.buttons["Hide Keyboard"].tap() }
    if app.buttons["BackButton"].isHittable { app.buttons["BackButton"].tap() }
    let release = app.buttons["release-publication"]
    try await waitUntil("the leaving publication to park") { release.exists }
    let row = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library-note-", "Parked thought")
    ).firstMatch
    try await waitUntil("the parked note's row") { row.isHittable }
    row.swipeLeft()
    let delete = app.buttons["Delete"]
    try await waitUntil("Delete on the parked note") { delete.isHittable }
    delete.tap()
    let confirmation = app.buttons["Delete"].firstMatch
    try await waitUntil("the parked note's deletion confirmation") { confirmation.isHittable }
    XCTAssertTrue(app.staticTexts["Delete “Parked thought”?"].exists)
    record(app, name: "parked-delete-confirmation")
    confirmation.tap()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(row.exists, "The deletion should wait for the publication to settle.")
    release.tap()
    try await waitUntil("the parked note to leave the list once publication settles") { !row.exists }
    XCTAssertFalse(app.alerts.firstMatch.exists)
    record(app, name: "parked-delete-result")
  }

  @MainActor
  private func checkAutomaticPublicationDeletion(leaving: Bool, contextMenu: Bool) async throws {
    let app = launch(dark: leaving, autosave: true)
    defer { app.terminate() }
    let create = app.buttons["library-create"]
    try await waitUntil("the New Note button") { create.isHittable }
    create.tap()
    let editor = app.textViews["source-editor"]
    try await waitUntil("the new note's editor") { editor.isHittable }
    editor.typeText("Delete this")
    if app.buttons["Hide Keyboard"].isHittable { app.buttons["Hide Keyboard"].tap() }
    let row = app.descendants(matching: .any)["library-note-newcapture"].firstMatch
    if !leaving {
      try await waitUntil("the five-second autosave's publication") {
        row.exists || app.buttons["note-comments"].exists
      }
    }
    if app.buttons["BackButton"].isHittable { app.buttons["BackButton"].tap() }
    try await waitUntil("the automatically published row without refreshing") { row.isHittable }
    if contextMenu { row.press(forDuration: 0.8) }
    else { row.swipeLeft() }
    let delete = app.buttons["Delete"]
    try await waitUntil("Delete on the automatically published gist") { delete.isHittable }
    delete.tap()
    let confirmation = app.buttons["Delete"].firstMatch
    try await waitUntil("the new gist's deletion confirmation") { confirmation.isHittable }
    record(
      app,
      name: "new-\(leaving ? "leave-note" : "autosave")-\(contextMenu ? "context" : "swipe")-delete")
    confirmation.tap()
    try await waitUntil("the new gist to be deleted without refreshing") { !row.exists }
    XCTAssertFalse(app.alerts.firstMatch.exists)
    XCTAssertTrue(app.descendants(matching: .any)["library-note-a"].firstMatch.exists)
  }

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
    let confirmation = app.buttons["Delete"].firstMatch
    try await waitUntil("the existing deletion confirmation") { confirmation.isHittable }
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
    let confirmation = app.buttons["Delete"].firstMatch
    try await waitUntil("the existing deletion confirmation") { confirmation.isHittable }
    XCTAssertTrue(app.staticTexts["Delete “A finished thought”?"].exists)
    XCTAssertTrue(row.exists)
    record(app, name: "library-delete-confirmation-\(dark ? "Dark" : "Light")")
    confirmation.tap()
    try await waitUntil("the successfully deleted synthetic gist to leave") { !row.exists }
    XCTAssertTrue(app.descendants(matching: .any)["library-note-a"].firstMatch.exists)
    app.collectionViews.firstMatch.swipeDown()
    try await waitUntil("the stale list to keep the deleted row excluded") {
      !row.exists && app.descendants(matching: .any)["library-note-a"].firstMatch.isHittable
    }
    record(app, name: "library-delete-after-stale-refresh-\(dark ? "Dark" : "Light")")
  }

  @MainActor
  private func launch(
    dark: Bool, localCopies: Bool = false, autosave: Bool = false, publicationHold: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", "library-delete", "--capture-stale-deletion",
      "--capture-appearance", dark ? "dark" : "light",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
    ]
    if localCopies { app.launchArguments.append("--capture-local-copies") }
    if autosave {
      app.launchArguments += ["--capture-autosave", "--capture-slow-publication-metadata"]
    }
    if publicationHold { app.launchArguments.append("--capture-publication-hold") }
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
