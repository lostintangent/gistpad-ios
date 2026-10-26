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
    try await waitUntil("the software keyboard inside the actual window") {
      let keyboard = app.keyboards.firstMatch
      return keyboard.exists && keyboard.frame.height >= 150
        && app.windows.firstMatch.frame.intersection(keyboard.frame).height >= 150
    }
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
  func testCachedOpeningIsAccessibleWithoutAnIncidentalTintWrapper() async throws {
    for appearance in ["light", "dark"] {
      for empty in [false, true] {
        let app = launch(
          screen: "note-loading", state: empty ? "cached-empty" : "cached",
          accessibility: true, appearance: appearance)
        defer {
          record(app, name: "native-cached-opening-\(empty ? "empty" : "words")-AX3-\(appearance)")
          app.terminate()
        }
        let cached = app.descendants(matching: .any)["opening-cached-note"].firstMatch
        try await waitUntil("the actual cached-note accessibility element") {
          cached.exists && cached.isHittable
        }
        XCTAssertGreaterThan(cached.frame.width, 0)
        XCTAssertGreaterThan(cached.frame.height, 0)
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(cached.frame))
        XCTAssertFalse(app.descendants(matching: .any)["opening-note-progress"].exists)
        if !empty {
          try await waitUntil("the accessible rendered cached words") {
            app.webViews.staticTexts["Saved words"].exists
          }
        }
      }
    }
  }

  @MainActor
  func testPhotoShelfHasARealAccessibleTargetAtAccessibilitySize() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(
        screen: "photos", state: "multiple", accessibility: true, appearance: appearance)
      defer {
        record(app, name: "native-photo-summary-AX3-\(appearance)-final")
        app.terminate()
      }
      func visibleSummaries() -> [XCUIElement] {
        app.buttons.matching(identifier: "pending-photos-summary")
          .allElementsBoundByIndex.filter(\.isHittable)
      }
      try await waitUntil("one actual accessible photo-summary target") { visibleSummaries().count == 1 }
      let summary = try XCTUnwrap(visibleSummaries().first)
      XCTAssertGreaterThan(summary.frame.width, 0)
      XCTAssertGreaterThanOrEqual(summary.frame.height, 44)
      XCTAssertLessThanOrEqual(summary.frame.height + 16, 180)
      XCTAssertTrue(app.windows.firstMatch.frame.contains(summary.frame))
      XCTAssertEqual(summary.label, "3 photos")
      XCTAssertEqual(summary.value as? String, "3 couldn't upload")
      record(app, name: "native-photo-summary-AX3-\(appearance)")
      summary.tap()
      try await waitUntil("the real photo Details presentation") {
        app.navigationBars["Photos"].exists && !summary.isHittable
      }
      XCTAssertTrue(app.buttons.matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "photo-recovery-")).firstMatch.exists)
    }
  }

  @MainActor
  func testLibrarySearchActivatesTheNativeFieldInLightAndDark() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(screen: "library", state: "search", appearance: appearance)
      defer { app.terminate() }
      let field = app.searchFields.firstMatch
      if !field.isHittable {
        let search = app.buttons["Search"].firstMatch
        try await waitUntil("the real Library Search command") { search.isHittable }
        search.tap()
      }
      try await waitUntil("the visible native search field") { field.isHittable }
      field.tap()
      XCTAssertEqual(field.value as? String, "notebook")
      field.typeText(" thought")
      XCTAssertEqual(field.value as? String, "notebook thought")
      record(app, name: "native-library-search-\(appearance)")
    }
  }

  @MainActor
  func testHomeKeepsItsMainCountAndUsesNativeSecondaryDisclosures() async throws {
    let collections = [
      (id: "dailyNotes", title: "Daily Notes", count: "2 notes", noteID: "daily-overdue"),
      (id: "starred", title: "Starred Gists", count: "1 gist", noteID: "starred"),
      (id: "archive", title: "Archived Gists", count: "1 gist", noteID: "archived"),
    ]
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        let app = launch(
          screen: "library", state: "collections-expanded", accessibility: accessibility,
          appearance: appearance)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let bar = app.navigationBars["GistPad"]
        let list = app.collectionViews.firstMatch
        try await waitUntil("Home's stable title and published-main-gist subtitle") {
          bar.exists && bar.staticTexts["5 gists"].exists && list.exists
        }
        XCTAssertFalse(list.staticTexts["Pinned"].exists)
        XCTAssertFalse(list.staticTexts["Your Gists"].exists)
        XCTAssertFalse(list.buttons["library-today"].exists)
        for collection in collections {
          let header = app.buttons["library-collection-\(collection.id)"].firstMatch
          let row = app.descendants(matching: .any)["library-note-\(collection.noteID)"].firstMatch
          try await reveal(header, in: list)
          XCTAssertEqual(header.label, collection.title)
          XCTAssertTrue((header.value as? String ?? "").contains(collection.count))
          XCTAssertGreaterThanOrEqual(header.frame.height, 44)
          XCTAssertTrue(window.frame.contains(header.frame))
          try await reveal(row, in: list)
          if collection.id == "dailyNotes" {
            XCTAssertTrue(row.label.contains("3 of 4 tasks complete"))
            XCTAssertTrue(row.label.contains("Unfinished tasks"))
            XCTAssertFalse(row.label.contains(".md"))
            XCTAssertFalse(row.label.contains("2 files"))
            XCTAssertFalse(row.label.contains("ago"))
          }
          record(
            app,
            name: "home-\(collection.id)-\(accessibility ? "AX3" : "Large")-\(appearance)")
        }
      }
    }
  }

  @MainActor
  func testHomeNeverShowsEmptyCollectionSections() async throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        let app = launch(
          screen: "library", state: "collections-empty", accessibility: accessibility,
          appearance: appearance)
        defer { app.terminate() }
        let list = app.collectionViews.firstMatch
        try await waitUntil("the ordinary gist with known empty secondary collections") {
          list.exists && app.navigationBars["GistPad"].staticTexts["1 gist"].exists
            && app.descendants(matching: .any)["library-note-weekend"].firstMatch.isHittable
        }
        XCTAssertEqual(app.buttons.matching(
          NSPredicate(format: "identifier BEGINSWITH %@", "library-collection-")).count, 0)
        record(app, name: "home-no-empty-collections-\(accessibility ? "AX3" : "Large")-\(appearance)")
      }
    }
  }

  @MainActor
  func testHomeCardAndLongCollectionStatesAcrossAppearancesAndTextSizes() async throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        for state in ["no-pins", "three-pins", "long-library"] {
          let app = launch(
            screen: "library", state: state, accessibility: accessibility, appearance: appearance)
          defer { app.terminate() }
          let list = app.collectionViews.firstMatch
          try await waitUntil("the actual Library") { list.exists }
          if state == "no-pins" {
            XCTAssertFalse(app.descendants(matching: .any).matching(
              NSPredicate(format: "identifier BEGINSWITH %@", "library-featured-")).firstMatch.exists)
            let first = app.descendants(matching: .any)["library-note-shape"].firstMatch
            try await waitUntil("ordinary content without reserved feature space") { first.isHittable }
            let bar = app.navigationBars["GistPad"]
            XCTAssertLessThanOrEqual(first.frame.minY - max(bar.frame.maxY, list.frame.minY), 24)
          } else if state == "three-pins" {
            let first = app.descendants(matching: .any)["library-featured-shape"].firstMatch
            try await waitUntil("the first intrinsic pinned card") {
              first.isHittable
            }
            XCTAssertTrue(first.label.contains("The shape of a notebook"))
            XCTAssertTrue(first.label.contains("precise engine beneath the page"))
            XCTAssertTrue(first.label.contains("Design"))
            XCTAssertTrue(first.label.contains("Ideas"))
          } else {
            let daily = app.buttons["library-collection-dailyNotes"].firstMatch
            try await reveal(daily, in: list)
            XCTAssertTrue((daily.value as? String ?? "").contains("2 notes"))
            XCTAssertEqual(app.collectionViews.count, 1)
          }
          record(app, name: "home-\(state)-\(accessibility ? "AX3" : "Large")-\(appearance)")
        }
      }
    }
  }

  @MainActor
  func testTodayRailKeepsItsNativeTargetAndOpensTodayReadyToEdit() async throws {
    for appearance in ["light", "dark"] {
      for badge in [(state: "today-0", value: "No unfinished tasks"),
                    (state: "today-3", value: "3 unfinished tasks"),
                    (state: "today-99plus", value: "104 unfinished tasks")] {
        let app = launch(
          screen: "library", state: badge.state, accessibility: true, appearance: appearance)
        defer { app.terminate() }
        let today = app.buttons["library-today"].firstMatch
        try await waitUntil("the native Today action") { today.isHittable }
        XCTAssertEqual(app.buttons.matching(identifier: "library-today").count, 1)
        XCTAssertTrue(today.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(today.frame))
        XCTAssertTrue("\(today.label) \(today.value as? String ?? "")".contains(badge.value))
        XCTAssertFalse(app.staticTexts["All done"].exists)
        record(app, name: "today-rail-\(badge.state)-AX3-\(appearance)")
        try await checkTodayOpening(app, at: .zero)
      }
    }
  }

  @MainActor
  func testTodayRailAcceptsEveryEdgeOfIts44PointHitRegion() async throws {
    for offset in [
      CGVector(dx: -21, dy: 0), CGVector(dx: 21, dy: 0),
      CGVector(dx: 0, dy: -21), CGVector(dx: 0, dy: 21)
    ] {
      let app = launch(
        screen: "library", state: "today-99plus", accessibility: true, appearance: "light")
      defer { app.terminate() }
      try await checkTodayOpening(app, at: offset)
    }
  }

  @MainActor
  private func checkTodayOpening(_ app: XCUIApplication, at offset: CGVector) async throws {
    let today = app.buttons["library-today"].firstMatch
    try await waitUntil("the native Today action") { today.isHittable }
    today.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .withOffset(offset).tap()
    let editor = app.textViews.firstMatch
    let hideKeyboard = app.buttons["Hide Keyboard"].firstMatch
    try await waitUntil("the exact Today document opening in Edit with focus") {
      editor.isHittable && (editor.value as? String ?? "").hasPrefix("# Today")
        && app.segmentedControls.firstMatch.buttons["Edit"].isSelected
        && hideKeyboard.isHittable
    }
  }

  @MainActor
  func testSearchRevealsACollapsedCollectionWithoutRememberingThatExpansion() async throws {
    let app = launch(screen: "library", state: "populated")
    defer { app.terminate() }
    let list = app.collectionViews.firstMatch
    let archive = app.descendants(matching: .any)["library-collection-archive"].firstMatch
    let row = app.descendants(matching: .any)["library-note-archived"].firstMatch
    try await reveal(archive, in: list)
    XCTAssertFalse(row.exists)
    let field = app.searchFields.firstMatch
    if !field.isHittable {
      let search = app.buttons["Search"].firstMatch
      try await waitUntil("the native Search command") { search.isHittable }
      search.tap()
    }
    try await waitUntil("the native search field") { field.isHittable }
    field.tap()
    field.typeText("finished chapter")
    try await waitUntil("the archived match temporarily revealing its collection") { row.isHittable }
    XCTAssertFalse(app.staticTexts["No matching notes"].exists)
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "library-note-archived").count, 1)
    record(app, name: "home-search-reveals-collapsed-archive")
    let clear = field.buttons["Clear text"].firstMatch
    try await waitUntil("the native query-clear control") { clear.isHittable }
    clear.tap()
    let dismissSearch = app.buttons.matching(
      NSPredicate(format: "label IN %@", ["Cancel", "close"])).firstMatch
    try await waitUntil("the native Search dismissal control") { dismissSearch.isHittable }
    dismissSearch.tap()
    try await waitUntil("Search's keyboard to dismiss before scrolling Home") {
      app.keyboards.count == 0
    }
    try await reveal(archive, in: list)
    XCTAssertFalse(row.exists)
  }

  @MainActor
  func testAnOwnedStarredGistHasOneDeletionConfirmationAtItsChosenOccurrence() async throws {
    let app = launch(screen: "library", state: "collection-overlap")
    defer { app.terminate() }
    let list = app.collectionViews.firstMatch
    let row = app.descendants(matching: .any)["library-note-shape"].firstMatch
    try await reveal(row, in: list)
    row.swipeLeft()
    let delete = app.buttons["Delete"].firstMatch
    try await waitUntil("the selected Starred occurrence's pending Delete action") { delete.isHittable }
    delete.tap()
    let confirm = app.buttons["Delete from GitHub"].firstMatch
    try await waitUntil("one anchored deletion confirmation") { confirm.isHittable }
    XCTAssertEqual(app.buttons.matching(identifier: "Delete from GitHub").count, 1)
    XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
    record(app, name: "home-overlapping-starred-deletion-confirmation")
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.isHittable {
      cancel.tap()
    } else {
      app.navigationBars["GistPad"].coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    try await waitUntil("cancellation retaining the Starred occurrence") { row.isHittable }
    row.tap()
    let home = app.navigationBars["GistPad"]
    if home.isHittable {
      let starred = app.descendants(matching: .any)["library-collection-starred"].firstMatch
      try await reveal(starred, in: list)
      starred.tap()
      try await waitUntil("collapsing Starred without closing the selected document") {
        !row.exists && app.navigationBars.buttons.matching(
          NSPredicate(format: "label CONTAINS %@", "The shape of a notebook")).firstMatch.exists
      }
    }
  }

  @MainActor
  func testQuickCaptureExposesTheNativeEditorAtBothTextSizes() async throws {
    for appearance in ["light", "dark"] {
      for accessibility in [false, true] {
        let app = launch(
          screen: "capture-today", accessibility: accessibility, appearance: appearance)
        defer { app.terminate() }
        let editor = app.textViews["today-capture-input"]
        try await waitUntil("the actual Add to Today editor") { editor.isHittable }
        XCTAssertEqual(editor.label, "Text to add to Today")
        XCTAssertGreaterThanOrEqual(editor.frame.height, 44)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(editor.frame))
        let add = app.buttons["today-capture-add"]
        XCTAssertFalse(add.isEnabled)
        editor.tap()
        editor.typeText("A thought worth keeping.")
        try await waitUntil("Add to enable after real text entry") { add.isHittable && add.isEnabled }
        XCTAssertEqual(editor.value as? String, "A thought worth keeping.")
        record(app, name: "native-quick-capture-\(accessibility ? "AX3" : "Large")-\(appearance)")
      }
    }
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
    try await checkSegmentMatrix(accessibility: false, wide: false)
  }

  @MainActor
  func testNativeSegmentTargetsAcrossTitlesAndAppearancesAtAccessibilitySize() async throws {
    try await checkSegmentMatrix(accessibility: true, wide: false)
  }

  @MainActor
  func testNativeWideSegmentTargetsAcrossTitlesAndAppearances() async throws {
    try await checkSegmentMatrix(accessibility: false, wide: true)
  }

  @MainActor
  func testNativeWideSegmentTargetsAcrossTitlesAndAppearancesAtAccessibilitySize() async throws {
    try await checkSegmentMatrix(accessibility: true, wide: true)
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
  func testNativeLibrarySwipeActionsInLightAndDark() async throws {
    for appearance in ["light", "dark"] {
      for leading in [false, true] {
        let app = launch(screen: "library-delete", state: "native-swipes", appearance: appearance)
        defer { app.terminate() }
        let row = app.descendants(matching: .any)["library-note-b"].firstMatch
        try await waitUntil("the owned Library row") { row.isHittable }
        if leading {
          row.swipeRight()
        } else {
          row.swipeLeft()
        }
        let labels = leading ? ["Pin"] : ["Archive", "Delete"]
        for label in labels {
          let action = app.buttons[label]
          try await waitUntil("the native \(label) swipe action") { action.isHittable }
          XCTAssertGreaterThanOrEqual(action.frame.height, 44)
          XCTAssertTrue(app.frame.contains(action.frame))
        }
        record(app, name: "native-library-swipe-\(leading ? "leading" : "trailing")-\(appearance)")
      }
    }
  }

  @MainActor
  func testNativeTagEditSwipeInLightAndDark() async throws {
    for appearance in ["light", "dark"] {
      let app = launch(screen: "tags", appearance: appearance)
      defer { app.terminate() }
      try await waitUntil("the native Tags sheet") { app.buttons["tag-save"].isHittable }
      record(app, name: "native-tags-before-swipe-\(appearance)")
      let row = app.descendants(matching: .any)["tag-choice-ideas"].firstMatch
      try await waitUntil("the actual tag row") { row.exists }
      if !row.isHittable { app.collectionViews.firstMatch.swipeUp() }
      try await waitUntil("the native editable tag row") { row.isHittable }
      row.swipeLeft()
      let edit = app.buttons["Edit Tag…"]
      try await waitUntil("the native Edit Tag swipe action") { edit.isHittable }
      XCTAssertGreaterThanOrEqual(edit.frame.height, 44)
      XCTAssertTrue(app.frame.contains(edit.frame))
      record(app, name: "native-tag-edit-swipe-\(appearance)")
    }
  }

  @MainActor
  private func checkSegmentMatrix(accessibility: Bool, wide: Bool) async throws {
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
      for split in wide ? [false, true] : [false] {
        var baselineWidth: CGFloat?
        for title in titles {
          let app = launch(
            screen: "note-chrome", state: title.state, accessibility: accessibility,
            appearance: appearance,
            extraArguments: ["--capture-multi-file"] + (split ? ["--capture-split"] : []))
          defer { app.terminate() }
          let window = app.windows.firstMatch
          do {
            try await waitUntil("the actual \(wide ? "unfolded" : "folded") Duo viewport") {
              abs(window.frame.width - (wide ? 951 : 466)) <= 1
                && abs(window.frame.height - (wide ? 669 : 678)) <= 1
            }
          } catch {
            record(app, name: "native-mode-viewport-\(wide ? "unfolded" : "folded")")
            throw error
          }
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
          XCTAssertTrue(window.frame.contains(picker.frame))
          for label in labels {
            let target = picker.buttons[label]
            XCTAssertGreaterThanOrEqual(target.frame.width, minimum - 1)
            XCTAssertGreaterThanOrEqual(target.frame.height, 44)
            XCTAssertTrue(window.frame.contains(target.frame))
            target.tap()
            try await waitUntil("native \(label) selection") { target.isSelected }
          }
          let titleButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title.title)).firstMatch
          try await waitUntil("the hittable native title after mode changes") {
            titleButton.isHittable
          }
          XCTAssertLessThanOrEqual(titleButton.frame.maxX, picker.frame.minX + 1)
          record(
            app,
            name: "native-\(title.state)-\(wide ? "unfolded" : "folded")-\(split ? "three" : "two")-\(accessibility ? "AX3" : "Large")-\(appearance)")
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
    screen: String, state: String? = nil, accessibility: Bool = false,
    appearance: String? = nil, extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: "dev.gistpad.GistPad")
    app.launchArguments = [
      "--capture-screen", screen, "--capture-accent", "#FACC15",
      "-UIPreferredContentSizeCategoryName",
      accessibility ? "UICTContentSizeCategoryAccessibilityXL" : "UICTContentSizeCategoryL"
    ]
    if let state {
      app.launchArguments += ["--capture-state", state]
    }
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
  private func reveal(_ element: XCUIElement, in list: XCUIElement) async throws {
    try await waitUntil("the native Library list") { list.exists }
    for _ in 0..<10 {
      if element.isHittable { return }
      if element.exists, element.frame.maxY <= list.frame.minY {
        list.swipeDown()
      } else {
        list.swipeUp()
      }
    }
    let tree = XCTAttachment(string: list.debugDescription)
    tree.name = "unrevealed-library-control"
    tree.lifetime = .keepAlways
    add(tree)
    try await waitUntil("the requested Library control") { element.isHittable }
  }

  @MainActor
  private func record(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
    let tree = XCTAttachment(
      string: "Application frame: \(app.frame)\nWindow frame: \(app.windows.firstMatch.frame)\n\(app.debugDescription)")
    tree.name = "\(name)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
  }
}

private enum NativeControlFailure: Error { case timedOut }
