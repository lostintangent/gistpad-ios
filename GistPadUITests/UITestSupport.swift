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

  /// The sidebar keeps secondary actions in its More menu. A compact Library shows them directly.
  func tapToolbarButton(_ identifier: String, label: String) {
    let button = buttons[identifier].firstMatch
    let more = navigationBars["GistPad"].buttons["More"].firstMatch
    if !button.isHittable, more.isHittable {
      more.tap()
      let item = buttons[label].firstMatch
      XCTAssertTrue(item.waitForExistence(timeout: 5))
      item.tap()
    } else {
      button.tap()
    }
  }

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

  /// Returns to the Library: Back in a stack, or nothing when the sidebar is already showing.
  func showLibrary() {
    let back = navigationBars.buttons["BackButton"].firstMatch
    if back.isHittable { back.tap() }
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
}

struct UITestTimeout: Error {}
