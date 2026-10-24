import XCTest

@MainActor
final class MutedMarkerUITests: XCTestCase {
    func testMarkersInEachNativeAppearanceAndSavedAccent() {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            for increased in [false, true] {
                for (accent, accentName) in [("#FACC15", "yellow"), ("#FF00FF", "magenta")] {
                    for source in [false, true] {
                        let app = XCUIApplication()
                        app.launchArguments = [
                            "--capture-screen", "note", "--capture-marker-fixture",
                            "--capture-appearance", appearance, "--capture-accent", accent,
                            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"
                        ]
                        if increased { app.launchArguments.append("--capture-increased-contrast") }
                        if source { app.launchArguments.append("--capture-source") }
                        app.launch()
                        let mode = app.segmentedControls["note-toggle-mode"].buttons[source ? "Edit" : "Preview"]
                        XCTAssertTrue(mode.waitForExistence(timeout: 15))
                        XCTAssertTrue(mode.isSelected)
                        if source {
                            let editor = app.textViews["source-editor"]
                            XCTAssertTrue(editor.waitForExistence(timeout: 10))
                            XCTAssertTrue((editor.value as? String)?.contains("3. An authored number") == true)
                            XCTAssertTrue((editor.value as? String)?.contains("- [x] Keep the good parts") == true)
                        } else {
                            let task = app.webViews.descendants(matching: .any).matching(
                                NSPredicate(format: "label IN %@", [
                                    "Read-only task: Leave room for a surprise",
                                    "Mark complete: Leave room for a surprise"
                                ])
                            ).firstMatch
                            XCTAssertTrue(task.waitForExistence(timeout: 15))
                        }
                        let image = XCTAttachment(screenshot: app.screenshot())
                        image.name = "muted-\(source ? "edit" : "preview")-\(appearance)-\(increased ? "increased" : "normal")-\(accentName)"
                        image.lifetime = .keepAlways
                        add(image)
                        app.terminate()
                    }
                }
            }
        }
    }
}
