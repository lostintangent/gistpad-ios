import XCTest

/// Launches the real app against the fixture GitHub through the launch contract in `FixtureLaunch`.
@MainActor
func launchGistPad(
  _ fixture: String = "standard", open: String? = nil, mode: String? = nil, sheet: String? = nil
) -> XCUIApplication {
  let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
  app.launchArguments = ["--fixture", fixture, "-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
  for (flag, value) in [("--open", open), ("--mode", mode), ("--sheet", sheet)] {
    if let value { app.launchArguments += [flag, value] }
  }
  app.launch()
  return app
}

extension XCUIElement {
  /// The first descendant of any type with this accessibility identifier.
  func element(_ identifier: String) -> XCUIElement {
    descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Library rows, which are the only elements whose identifiers start with `library-note-`.
  var libraryRows: XCUIElementQuery {
    descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'library-note-'"))
  }

  /// A web view element whose text starts with `prefix`.
  func passage(_ prefix: String) -> XCUIElement {
    webViews.firstMatch.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
  }
}

extension XCUIApplication {
  var isRegularWidth: Bool { windows.firstMatch.frame.width > 600 }

  /// Opens Library search and types `text`.
  func search(_ text: String) {
    let field = searchFields.firstMatch
    if !field.isHittable { buttons["Search"].firstMatch.tap() }
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(text)
  }

  /// Whether the open note shows `text` in its editor or its Preview.
  func noteShows(_ text: String) -> Bool {
    if let source = textViews["source-editor"].value as? String, source.contains(text) { return true }
    return webViews.firstMatch.staticTexts
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
  }

  /// Hides the sidebar when it overlays the note, as the system's split view shows it at launch
  /// in unfolded portrait. Does nothing when the sidebar sits beside the note or isn't showing.
  func dismissSidebarOverlay() {
    let sidebar = element("library-list")
    let note = navigationBars.matching(NSPredicate(format: "identifier != 'GistPad'")).firstMatch
    guard sidebar.isHittable, note.exists, note.frame.minX < sidebar.frame.maxX else { return }
    buttons.matching(NSPredicate(format: "label == 'Hide Sidebar'")).allElementsBoundByIndex
      .first(where: \.isHittable)?.tap()
    XCTAssertTrue(sidebar.wait(for: \.isHittable, toEqual: false, timeout: 5), "The sidebar still covers the note")
  }

  /// The note's More button, or the system's overflow button when the toolbar is too narrow for
  /// More, as a gist with a title menu is in unfolded portrait.
  var moreButton: XCUIElement {
    let actions = buttons["note-actions"]
    return actions.exists ? actions : buttons["TopOverflowBarButtonItem"]
  }

  /// Shows the sidebar when the unfolded Duo hides it, as it does once the overlay is dismissed.
  func showSidebar() {
    let show = buttons.matching(NSPredicate(format: "label == 'Show Sidebar'")).firstMatch
    guard isRegularWidth, show.waitForExistence(timeout: 2), show.isHittable else { return }
    show.tap()
    XCTAssertTrue(element("library-list").waitForExistence(timeout: 5), "The sidebar never showed")
  }

  /// Returns to the Library: Back in a stack, or the sidebar when the Duo is open.
  func showLibrary() {
    guard !isRegularWidth else { return showSidebar() }
    // The Duo's cover floats Back beside the bar, outside the navigation bar's subtree.
    let back = buttons["BackButton"].firstMatch
    XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 10), "Back never became tappable")
    back.tap()
  }
}

extension XCTestCase {
  @MainActor
  func waitUntil(
    _ description: String, timeout: TimeInterval = 15, file: StaticString = #filePath,
    line: UInt = #line, _ ready: () -> Bool
  ) throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if ready() { return }
      RunLoop.current.run(until: .now.addingTimeInterval(0.1))
    }
    XCTFail("Timed out waiting for \(description).", file: file, line: line)
    throw UITestTimeout()
  }
}

extension XCTestCase {
  /// Taps `element` once it can be tapped, since menus and swipe actions animate in.
  @MainActor
  func tap(
    _ element: XCUIElement, _ description: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try waitUntil(description, file: file, line: line) { element.isHittable }
    element.tap()
  }

  /// Opens the note's More menu, first dismissing a sidebar that overlays the note, and through
  /// the system's overflow menu when the toolbar moved More there.
  @MainActor
  func openNoteActions(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
    app.dismissSidebarOverlay()
    // The title can land a frame before the toolbar's items.
    try waitUntil("More", file: file, line: line) {
      app.buttons["note-actions"].exists || app.buttons["TopOverflowBarButtonItem"].exists
    }
    let more = app.moreButton
    let overflows = more.identifier == "TopOverflowBarButtonItem"
    try tap(more, "More", file: file, line: line)
    guard overflows else { return }
    try tap(
      app.buttons.matching(NSPredicate(format: "label == 'More' AND identifier == ''")).firstMatch,
      "More in the overflow menu", file: file, line: line)
  }

  /// Taps the destructive button in the confirmation dialog that a Delete action presents.
  @MainActor
  func confirmDeletion(in app: XCUIApplication) throws {
    var confirm: XCUIElement?
    try waitUntil("the delete confirmation") {
      confirm = app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.last(where: \.isHittable)
      return confirm != nil
    }
    confirm?.tap()
  }
}

struct UITestTimeout: Error {}
