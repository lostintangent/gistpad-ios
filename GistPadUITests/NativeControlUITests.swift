import UIKit
import XCTest

final class NativeControlUITests: XCTestCase {
  @MainActor
  func testRetryRetainsTheProblemAndReturnsToTheOpenSource() async throws {
    try await checkSourceRecovery(accessibility: false)
  }

  @MainActor
  func testRetryRetainsTheProblemAtAccessibilitySize() async throws {
    try await checkSourceRecovery(accessibility: true)
  }

  @MainActor
  private func checkSourceRecovery(accessibility: Bool) async throws {
    let app = launch(screen: "note", state: "status-error", accessibility: accessibility)
    defer { app.terminate() }
    let attention = app.buttons["github-status-attention"]
    try await waitUntil("the unresolved GitHub problem") { attention.isHittable }
    let problem = try XCTUnwrap(attention.value as? String)
    XCTAssertGreaterThanOrEqual(attention.frame.width, 44)
    XCTAssertGreaterThanOrEqual(attention.frame.height, 44)
    let edit = app.segmentedControls.firstMatch.buttons["Edit"]
    try await waitUntil("the native Edit segment") { edit.isHittable }
    edit.tap()
    let editor = app.textViews.firstMatch
    try await waitUntil("the editable source") { editor.isHittable }
    let source = try XCTUnwrap(editor.value as? String)
    try await waitUntil("the software keyboard") { app.keyboards.firstMatch.exists }
    record(app, name: "source-with-keyboard-before-status")
    try await waitUntil("the covered status leaving the accessibility tree") { !attention.exists }
    let hideKeyboard = app.buttons["Hide Keyboard"]
    try await waitUntil("the native Hide Keyboard command") { hideKeyboard.isHittable }
    hideKeyboard.tap()
    try await waitUntil("the unresolved problem returning after keyboard dismissal") {
      !app.keyboards.firstMatch.exists && attention.isHittable
    }
    XCTAssertEqual(attention.value as? String, problem)
    record(app, name: "source-after-keyboard-status-restored")
    attention.tap()
    let retry = app.buttons["github-status-recover"]
    try await waitUntil("a visible and enabled Retry") { retry.isHittable && retry.isEnabled }
    if accessibility, !app.frame.insetBy(dx: 0, dy: 16).contains(retry.frame) {
      app.scrollViews.firstMatch.swipeUp()
      try await waitUntil("the complete native recovery target") {
        app.frame.insetBy(dx: 0, dy: 16).contains(retry.frame)
      }
    }
    record(app, name: "status-details-native-swiftui")
    XCTAssertEqual(retry.label, "Retry")
    XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
    retry.tap()
    try await waitUntil("the retained, disabled recovery button") { retry.exists && !retry.isEnabled }
    try await waitUntil("successful recovery to dismiss details") { !retry.exists }
    XCTAssertFalse(attention.exists)
    XCTAssertEqual(editor.value as? String, source)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
  }

  @MainActor
  func testRetryBecomesEnabledAtItsDeadlineWithoutAnotherModelUpdate() async throws {
    let app = launch(screen: "note", state: "status-limited")
    defer { app.terminate() }
    let attention = app.buttons["github-status-attention"]
    try await waitUntil("the rate-limited attention button") { attention.isHittable }
    attention.tap()
    let retry = app.buttons["github-status-recover"]
    try await waitUntil("the rate-limited recovery button") { retry.exists }
    XCTAssertFalse(retry.isEnabled)
    try await waitUntil("the actual retry deadline", timeout: .seconds(20)) {
      retry.isEnabled && retry.isHittable
    }
    retry.tap()
    try await waitUntil("successful recovery") { !retry.exists && !attention.exists }
  }

  @MainActor
  func testLongRequestKeepsAnAccessibleCancelDuringAZeroAnswerWait() async throws {
    try await checkPendingCancellation(accessibility: false)
  }

  @MainActor
  func testLongRequestKeepsAnAccessibleCancelAtAccessibilitySize() async throws {
    try await checkPendingCancellation(accessibility: true)
  }

  @MainActor
  func testEmojiTitleKeepsBothModesVisible() async throws {
    try await checkNativeModes(accessibility: false)
  }

  @MainActor
  func testEmojiTitleKeepsBothModesVisibleAtAccessibilitySize() async throws {
    try await checkNativeModes(accessibility: true)
  }

  @MainActor
  func testNativeFileAndDocumentMenusInLightAndDark() async throws {
    for appearance in ["light", "dark"] {
      for titleMenu in [true, false] {
        let app = launch(
          screen: "note-chrome", state: "native-controls", appearance: appearance,
          extraArguments: ["--capture-multi-file"])
        defer { app.terminate() }
        let trigger = titleMenu
          ? app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "A place for good ideas")).firstMatch
          : app.buttons["note-actions"]
        try await waitUntil("the native menu trigger") { trigger.isHittable }
        trigger.tap()
        let expected = titleMenu
          ? ["README.md", "Ideas.md", "Rename File…", "Add File…"]
          : ["Rename Note…", "Intelligence…", "Archive", "Delete Note…"]
        for label in expected {
          try await waitUntil("the native \(label) menu command") { app.buttons[label].exists }
        }
        if titleMenu { XCTAssertFalse(app.buttons["Rename Note…"].exists) }
        record(app, name: "native-\(titleMenu ? "file" : "document")-menu-\(appearance)")
      }
    }
  }

  @MainActor
  func testNativeAutosaveAndOfflineControlsRemainIndependent() async throws {
    let presentations = [
      (state: "save-local", save: false, offline: false),
      (state: "save-unsaved", save: false, offline: false),
      (state: "save-publishing", save: false, offline: false),
      (state: "save-published", save: false, offline: false),
      (state: "save-offline", save: false, offline: true),
      (state: "save-failed", save: true, offline: false),
      (state: "save-manual", save: true, offline: false),
    ]
    for presentation in presentations {
      let app = launch(screen: "note-chrome", state: presentation.state)
      defer { app.terminate() }
      try await waitUntil("the native note chrome") { app.buttons["note-actions"].isHittable }
      XCTAssertEqual(app.buttons["note-save"].exists, presentation.save, presentation.state)
      XCTAssertEqual(app.buttons["note-offline"].exists, presentation.offline, presentation.state)
      if presentation.state == "save-failed" {
        XCTAssertTrue(app.buttons["note-save"].isEnabled)
        XCTAssertTrue(app.buttons["note-save-retry"].exists)
      } else {
        XCTAssertFalse(app.descendants(matching: .any)["note-save-issue"].exists)
        XCTAssertFalse(app.buttons["note-save-retry"].exists)
      }
      if presentation.offline {
        app.buttons["note-offline"].tap()
        try await waitUntil("the native offline explanation") { app.alerts.firstMatch.exists }
        XCTAssertTrue(app.alerts.buttons["Retry"].isHittable)
        app.alerts.buttons["Close"].tap()
      }
      record(app, name: "native-\(presentation.state)")
    }
  }

  @MainActor
  func testNativeSaveAndActionsRemainAvailableInEachMode() async throws {
    for source in [false, true] {
      let app = launch(
        screen: "note-chrome", state: "save-manual",
        extraArguments: source ? ["--capture-source"] : [])
      defer { app.terminate() }
      try await waitUntil("native Save and note actions") {
        app.buttons["note-save"].isHittable && app.buttons["note-actions"].isHittable
      }
      XCTAssertTrue(app.segmentedControls["note-toggle-mode"].exists)
      record(app, name: "native-shared-background-\(source ? "Edit" : "Preview")")
    }
  }

  @MainActor
  func testNativeSegmentTargetsAcrossTitlesAndAppearances() async throws {
    try await checkSegmentMatrix(accessibility: false)
  }

  @MainActor
  func testNativeSegmentTargetsAcrossTitlesAndAppearancesAtAccessibilitySize() async throws {
    try await checkSegmentMatrix(accessibility: true)
  }

  @MainActor
  func testNativeCloseReturnsToTheRetainedEditableSource() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(screen: "intelligence", state: "edit", appearance: appearance)
      defer { app.terminate() }
      let close = app.buttons["intelligence-close"]
      try await waitUntil("the result and native Close") {
        app.buttons["intelligence-apply"].exists && close.isHittable
      }
      close.tap()
      let editor = app.textViews["source-editor"]
      try await waitUntil("Close to restore the original source") {
        editor.isHittable && !close.exists
      }
      let source = "# Saturday walk\n\nTake teh river path.\nLeave at 9am, before the cafe opens at 8am."
      XCTAssertEqual(editor.value as? String, source)
      record(app, name: "native-close-retained-source-\(appearance)")
      editor.tap()
      editor.typeText("\nStill editable.")
      XCTAssertEqual(
        (editor.value as? String)?.replacingOccurrences(of: "\nStill editable.", with: ""), source)
    }
  }

  @MainActor
  private func checkSegmentMatrix(accessibility: Bool) async throws {
    let titles = [
      (state: "mode-short", title: "A note"),
      (
        state: "mode-long",
        title: "A very long notebook title that must yield its space to the complete editing controls while leaving every reading, writing and navigation action intact"
      ),
      (state: "mode-emoji", title: "💔 OSS Maintainers: A Three-Part Tragedy"),
    ]
    let category: UIContentSizeCategory = accessibility ? .accessibilityExtraLarge : .large
    let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(
      for: 48, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    for appearance in ["light", "dark"] {
      for split in [false, true] {
        var baselineWidth: CGFloat?
        for title in titles {
          let app = launch(
            screen: "note-chrome", state: title.state, accessibility: accessibility,
            appearance: appearance,
            extraArguments: ["--capture-multi-file"] + (split ? ["--capture-split"] : []))
          defer { app.terminate() }
          let picker = app.segmentedControls["note-toggle-mode"]
          let labels = split ? ["Edit", "Split", "Preview"] : ["Edit", "Preview"]
          try await waitUntil("every native mode target") {
            labels.allSatisfy { picker.buttons[$0].isHittable }
          }
          XCTAssertEqual(picker.buttons.count, labels.count)
          if let baselineWidth {
            XCTAssertEqual(picker.frame.width, baselineWidth, accuracy: 1)
          } else {
            baselineWidth = picker.frame.width
          }
          XCTAssertTrue(app.frame.contains(picker.frame))
          for label in labels {
            let target = picker.buttons[label]
            XCTAssertGreaterThanOrEqual(target.frame.width, minimum - 1)
            XCTAssertGreaterThanOrEqual(target.frame.height, 44)
            XCTAssertTrue(picker.frame.insetBy(dx: -1, dy: -1).contains(target.frame))
            target.tap()
            try await waitUntil("native \(label) selection") { target.isSelected }
          }
          let titleButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title.title)).firstMatch
          XCTAssertTrue(titleButton.exists)
          XCTAssertLessThanOrEqual(titleButton.frame.maxX, picker.frame.minX + 1)
          record(
            app,
            name: "native-\(title.state)-\(split ? "three" : "two")-\(accessibility ? "AX3" : "Large")-\(appearance)")
        }
      }
    }
  }

  @MainActor
  private func checkPendingCancellation(accessibility: Bool) async throws {
    let app = launch(screen: "intelligence", state: "pending-cancel", accessibility: accessibility)
    defer { app.terminate() }
    let cancel = app.buttons["intelligence-cancel"]
    let progress = app.descendants(matching: .any)["intelligence-progress"]
    let request = app.descendants(matching: .any)["intelligence-submitted-request"]
    try await waitUntil("the accessible empty-answer pending controls") {
      cancel.isHittable && progress.exists && progress.label == "Answering…" && request.exists
    }
    let started = ContinuousClock.now
    while started.duration(to: .now) < .seconds(5.1) {
      XCTAssertTrue(cancel.isHittable && cancel.isEnabled)
      XCTAssertTrue(progress.exists)
      XCTAssertTrue(app.frame.contains(progress.frame))
      if accessibility {
        XCTAssertTrue(app.frame.intersects(request.frame))
        XCTAssertLessThan(cancel.frame.maxY, request.frame.minY)
      } else {
        XCTAssertTrue(app.frame.contains(request.frame))
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTAssertEqual(cancel.label, "Cancel")
    XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
    XCTAssertGreaterThan(request.label.count, 200)
    XCTAssertFalse(app.buttons["intelligence-generate"].exists)
    record(app, name: "zero-answer-pending-\(accessibility ? "AX3" : "Large")")
    cancel.tap()
    let generate = app.buttons["intelligence-generate"]
    try await waitUntil("Cancel to restore the retained request") {
      generate.exists && generate.isEnabled && !cancel.exists
    }
    XCTAssertTrue(app.staticTexts["Cancelled. Your note is unchanged."].exists)
  }

  @MainActor
  private func checkNativeModes(accessibility: Bool) async throws {
    let app = launch(screen: "note", state: "mode-emoji", accessibility: accessibility)
    defer { app.terminate() }
    let picker = app.segmentedControls.firstMatch
    let edit = picker.buttons["Edit"]
    let preview = picker.buttons["Preview"]
    try await waitUntil("both uncompressed native mode targets") {
      edit.isHittable && preview.isHittable
    }
    for control in [edit, preview] {
      XCTAssertGreaterThanOrEqual(control.frame.width, 48)
      XCTAssertGreaterThanOrEqual(control.frame.height, 44)
      XCTAssertTrue(app.frame.contains(control.frame))
    }
    record(app, name: "mode-emoji-\(accessibility ? "AX3" : "Large")")
    preview.tap()
    try await waitUntil("Preview selection") { preview.isSelected }
    edit.tap()
    try await waitUntil("Edit selection") { edit.isSelected }
  }

  @MainActor
  private func launch(
    screen: String, state: String, accessibility: Bool = false,
    appearance: String? = nil, extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", screen, "--capture-state", state, "--capture-accent", "#FACC15",
      "-UIPreferredContentSizeCategoryName",
      accessibility ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
    ]
    if let appearance {
      app.launchArguments += ["--capture-appearance", appearance]
    }
    app.launchArguments += extraArguments
    app.launch()
    return app
  }

  @MainActor
  private func waitUntil(
    _ description: String, timeout: Duration = .seconds(8),
    file: StaticString = #filePath, line: UInt = #line,
    _ ready: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Timed out waiting for \(description).", file: file, line: line)
    throw NativeControlFailure.timedOut
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

private enum NativeControlFailure: Error { case timedOut }
