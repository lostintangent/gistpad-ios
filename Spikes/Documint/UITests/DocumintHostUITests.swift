import XCTest

@MainActor
final class DocumintHostUITests: XCTestCase {
    func testNativeAccessibilityAndKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--capture-screen", "documint"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        let ready = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " ms")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20))
        attach(app.debugDescription, name: "native-rich-accessibility-before-focus")
        attach(app.screenshot(), name: "native-rich-resting")

        let semanticText = web.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@", "A rich page", "Clean the kitchen"
        )).count
        attach("Visible authored heading/task static-text matches: \(semanticText)\n" +
            "This is the native XCTest accessibility tree, not a spoken VoiceOver test.",
            name: "native-accessibility-summary")

        web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.keyboards.firstMatch.frame.height, 100,
            "A keyboard AX container alone does not prove a visible software keyboard.")
        XCTAssertFalse(app.keyboards.firstMatch.frame.intersection(app.frame).isEmpty)
        XCTAssertLessThanOrEqual(web.frame.maxY, app.keyboards.firstMatch.frame.minY + 2,
            "The rich viewport must avoid the actual software keyboard.")
        app.typeText("spikeword teh ")
        attach(app.screenshot(), name: "native-rich-keyboard")
        attach(
            "Web viewport: \(web.frame)\nKeyboard: \(app.keyboards.firstMatch.frame)\n" +
            "Viewport avoids keyboard: \(web.frame.maxY <= app.keyboards.firstMatch.frame.minY + 2)",
            name: "native-keyboard-geometry"
        )

        web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).doubleTap()
        attach(app.debugDescription, name: "native-rich-selection-actions")
        attach(app.screenshot(), name: "native-rich-selection")
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).press(forDuration: 1)
        attach(app.debugDescription, name: "native-rich-long-press-actions")
        attach(app.screenshot(), name: "native-rich-long-press")
        attach("Native edit menus: \(app.menus.count)\n" +
            "Native Writing Tools buttons: \(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Writing Tools")).count)\n" +
            "Zero in this probe is not proof of system-wide unavailability.",
            name: "native-system-editing-actions")

        app.segmentedControls.buttons["Edit"].tap()
        let source = app.textViews["Markdown source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let sourceValue = try XCTUnwrap(source.value as? String)
        XCTAssertTrue(sourceValue.contains("spikeword"))
        attach(sourceValue.components(separatedBy: "\n").first ?? "",
            name: "native-typed-synthetic-heading")
        XCTAssertTrue(sourceValue.components(separatedBy: "\n").first?.contains("page") == true,
            "Typing into the heading must not remove untouched characters from 'page'.")
        attach("Native typed text reached the raw source.\n" +
            "Autocorrect changed 'teh': \(sourceValue.contains("spikeword the "))\n" +
            "Autocorrect retained 'teh': \(sourceValue.contains("spikeword teh "))",
            name: "native-typing-and-autocorrect-summary")
        attach(app.screenshot(), name: "native-source-after-rich-input")

        app.segmentedControls.buttons["Rich"].tap()
        web.swipeUp(velocity: .slow)
        attach(app.screenshot(), name: "native-rich-after-scroll")
        app.terminate()
    }

    func testDarkReadingAndImages() {
        let app = XCUIApplication()
        app.launchArguments = ["--capture-screen", "documint", "--capture-appearance", "dark"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", " ms")).firstMatch.waitForExistence(timeout: 20))
        attach(app.screenshot(), name: "native-rich-dark-resting")
        web.swipeUp(velocity: .slow)
        attach(app.screenshot(), name: "native-rich-dark-images")
        web.swipeUp(velocity: .slow)
        attach(app.screenshot(), name: "native-rich-dark-dialect")
        app.terminate()
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
