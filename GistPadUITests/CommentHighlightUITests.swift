import XCTest

@MainActor
final class CommentHighlightUITests: XCTestCase {
    func testCommentHighlightsInEachNativeAppearance() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for increased in [false, true] {
                for source in [false, true] {
                    let app = launch(source: source, appearance: appearance, increased: increased)
                    capture(app, name: "comments-\(source ? "edit" : "preview")-\(appearance)-\(increased ? "increased" : "normal")")
                    passage("First Passage", in: app)
                    expectStatus(app, contains: "|selected:10|")
                    capture(app, name: "comments-selected-\(source ? "edit" : "preview")-\(appearance)-\(increased ? "increased" : "normal")")
                    app.terminate()
                }
            }
        }
    }

    func testSourceOverlapTapAndNativeSelectionMenu() {
        continueAfterFailure = false
        let app = launch(source: true)
        passage("Locate Source Passage", in: app)
        let target = sourcePoint(in: app)
        target.tap()
        XCTAssertTrue(app.buttons["Thread 10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Thread 20"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["Thread 20"].tap()
        expectStatus(app, contains: "|selected:20|")
        expectStatus(app, contains: "|opened:10,20|")
        expectStatus(app, contains: "|opens:1|")
        capture(app, name: "comments-edit-overlap-opened")
        app.terminate()

        let selectionApp = launch(source: true)
        passage("Locate Source Passage", in: selectionApp)
        sourcePoint(in: selectionApp).doubleTap()
        XCTAssertTrue(selectionApp.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(selectionApp.buttons["Thread 10"].exists)
        activateAddComment(in: selectionApp)
        let quote = selectionApp.staticTexts["comment-capture-quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        XCTAssertEqual(quote.label, "native")
        capture(selectionApp, name: "comments-edit-native-selection-menu")
        selectionApp.buttons["Done"].tap()
        expectStatus(selectionApp, contains: "|generation:0")
        selectionApp.terminate()
    }

    func testPreviewOverlapTapAndNativeSelectionMenu() {
        continueAfterFailure = false
        let app = launch(source: false)
        let overlap = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "native")).firstMatch
        XCTAssertTrue(overlap.waitForExistence(timeout: 5))
        overlap.tap()
        XCTAssertTrue(app.buttons["Thread 10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Thread 20"].exists)
        app.buttons["Thread 20"].tap()
        expectStatus(app, contains: "|selected:20|")
        expectStatus(app, contains: "|opened:10,20|")
        expectStatus(app, contains: "|opens:1|")
        capture(app, name: "comments-preview-overlap-opened")
        app.terminate()

        let selectionApp = launch(source: false)
        let word = selectionApp.buttons["quiet"].firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        word.press(forDuration: 1)
        activateAddComment(in: selectionApp)
        let quote = selectionApp.staticTexts["comment-capture-quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        XCTAssertEqual(quote.label, "quiet")
        capture(selectionApp, name: "comments-preview-native-selection-menu")
        selectionApp.buttons["Done"].tap()
        expectStatus(selectionApp, contains: "|generation:0")
        selectionApp.terminate()
    }

    func testInitialSelectedPassageAtAccessibilitySize() {
        continueAfterFailure = false
        for source in [false, true] {
            let app = launch(
                source: source, category: "UICTContentSizeCategoryAccessibilityXL",
                selected: true)
            expectStatus(app, contains: "|selected:60|")
            let status = app.staticTexts["comment-capture-status"]
            if source {
                passage("Locate Selected Passage", in: app)
                let point = point(in: app)
                XCTAssertGreaterThan(point.y, app.navigationBars.firstMatch.frame.maxY)
                XCTAssertLessThan(point.y, status.frame.minY)
            } else {
                let passage = app.buttons["late native passage"].firstMatch
                XCTAssertTrue(passage.waitForExistence(timeout: 5))
                let visible = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"), object: passage)
                XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
                XCTAssertGreaterThan(passage.frame.minY, app.navigationBars.firstMatch.frame.maxY)
                XCTAssertLessThan(passage.frame.maxY, status.frame.minY)
            }
            capture(app, name: "comments-initial-selected-\(source ? "edit" : "preview")-AX3")
            app.terminate()
        }
    }

    private func launch(
        source: Bool, appearance: String = "light", increased: Bool = false,
        category: String = "UICTContentSizeCategoryL", selected: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--capture-screen", "comment-highlights", "--capture-appearance", appearance,
            "--capture-accent", "#FACC15", "-UIPreferredContentSizeCategoryName", category
        ]
        if source { app.launchArguments.append("--capture-source") }
        if increased { app.launchArguments.append("--capture-increased-contrast") }
        if selected { app.launchArguments.append("--capture-selected-comment") }
        app.launch()
        expectStatus(app, contains: "ready:1|")
        return app
    }

    private func passage(_ title: String, in app: XCUIApplication) {
        app.buttons["comment-capture-passages"].tap()
        let action = app.buttons[title]
        for _ in 0..<4 {
            if action.waitForExistence(timeout: 1) {
                action.tap()
                return
            }
            let menu = app.collectionViews.firstMatch
            guard menu.exists else { break }
            menu.swipeUp()
        }
        XCTFail("The Passages menu has no reachable \(title) action: \(app.debugDescription)")
    }

    private func expectStatus(_ app: XCUIApplication, contains value: String) {
        let status = app.staticTexts["comment-capture-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", value), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, status.label)
    }

    private func point(in app: XCUIApplication) -> CGPoint {
        let status = app.staticTexts["comment-capture-status"].label
        let field = status.split(separator: "|").first { $0.hasPrefix("tap:") }
        let values = field?.dropFirst(4).split(separator: ",").compactMap { Double($0) } ?? []
        guard values.count == 2 else {
            XCTFail("The native source range has no window point: \(status)")
            return .zero
        }
        return CGPoint(x: values[0], y: values[1])
    }

    private func sourcePoint(in app: XCUIApplication) -> XCUICoordinate {
        let location = point(in: app)
        let editor = app.textViews["source-editor"]
        return editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: location.x - editor.frame.minX, dy: location.y - editor.frame.minY))
    }

    private func activateAddComment(in app: XCUIApplication) {
        let action = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Add Comment")).firstMatch
        for _ in 0..<4 {
            if action.waitForExistence(timeout: 1) {
                action.tap()
                return
            }
            let next = app.buttons["Next Page"].firstMatch
            guard next.exists, next.isHittable else { break }
            next.tap()
        }
        XCTFail("The native selection menu has no reachable Add Comment action: \(app.debugDescription)")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
