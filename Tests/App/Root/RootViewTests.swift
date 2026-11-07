import Foundation
@testable import Editor
import Screens
import Platform
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad
@testable import Model
@testable import Store

@Suite(.serialized)
@MainActor
struct RootViewTests {
  @Test func reopeningPreviewThenEditKeepsTheSourceOnScreen() async throws {
    let source = """
      ---
      edit:
        instructions: >-
          Preserve the reading list's existing sections and entries.
      ---

      # A visible reading list

      """
      + (1...300).map { "\($0). A retained reading entry \($0)\n" }.joined()
      + "\nAn exact final source line."
    let other = "# Another note\n\nA different retained source."
    let fixture = try await ModelFixture(autosave: false) {
      $0.addGist(
        id: "reading", description: "Reading list",
        files: ["README.md": source, "Calendar.md": "# A second file"])
      $0.addGist(id: "other", description: "Another note", files: ["README.md": other])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact, mode: .preview)
    defer { await host.close() }
    var retained: UITextView?
    for id in ["reading", "other", "reading"] {
      let text = id == "reading" ? source : other
      host.model.open(rowID: id)
      try await host.waitUntil {
        host.model.visibleFile?.gist?.id == id && host.editor(text: text) != nil
          && host.picker != nil
      }
      let editor = try #require(host.editor(text: text))
      if id == "reading" {
        if let retained { #expect(editor === retained) } else { retained = editor }
      }
      if id == "other" {
        // Unfolding the Duo gives Split. Folding it again keeps the same source.
        let compactWidth = host.window.frame.width
        host.window.traitOverrides.horizontalSizeClass = .regular
        host.window.frame.size.width = 1180
        try await host.waitUntil { host.picker?.numberOfSegments == 3 }
        host.layout.select(.split)
        try await host.waitUntil { host.isVisible(editor) }
        host.window.traitOverrides.horizontalSizeClass = .compact
        host.window.frame.size.width = compactWidth
        try await host.waitUntil { host.picker?.numberOfSegments == 2 }
        host.layout.select(.preview)
      }
      for showsPreview in [true, false] {
        let picker = try #require(host.picker)
        picker.selectedSegmentIndex = showsPreview ? picker.numberOfSegments - 1 : 0
        picker.sendActions(for: .valueChanged)
        if showsPreview {
          let preview = try #require(host.descendants.compactMap { $0 as? WKWebView }.first)
          var rendered = false
          // WebKit's content process can take several seconds to start while the suite runs.
          let deadline = ContinuousClock.now.advanced(by: .seconds(15))
          while !rendered, ContinuousClock.now < deadline {
            rendered = try await preview.callAsyncJavaScript(
              "return document.body.innerText.includes('retained');",
              arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            if !rendered { try await Task.sleep(for: .milliseconds(100)) }
          }
          #expect(rendered)
        } else {
          try await host.waitForKeyboard(visible: true)
          let position = try #require(editor.selectedTextRange?.end)
          let caret = editor.convert(editor.caretRect(for: position), to: host.window)
          let bar = try #require(host.descendants.compactMap { $0 as? UINavigationBar }.last)
          let top = bar.convert(bar.bounds, to: host.window).maxY
          #expect(editor.isFirstResponder)
          #expect(host.isVisible(editor))
          #expect(editor.text.utf8.elementsEqual(text.utf8))
          #expect(
            editor.selectedRange
              == NSRange(location: Syntax.contentStart(in: text), length: 0))
          #expect(caret.minY >= top - 1 && caret.minY < top + 40)
          editor.resignFirstResponder()
          try await host.waitForKeyboard(visible: false)
          #expect(host.isVisible(editor))
        }
      }
      host.returnToLibrary()
      try await host.waitUntil { host.isLibraryVisible }
    }
  }

  @Test func leavingANewBlankNoteLeavesNothingBehind() async throws {
    let fixture = try await ModelFixture {
      $0.addGist(id: "kept", description: "Kept", files: ["README.md": "A real note"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    // Creating is local, so it works offline.
    fixture.fail()
    await host.model.open(.new)
    let first = try #require(host.model.visibleFile?.nextDraft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    #expect(host.editor(text: "")?.selectedRange == NSRange(location: 0, length: 0))
    try await host.waitForKeyboard(visible: true)
    fixture.restore()
    host.pending.link = .gist(id: "kept", filename: nil)
    try await host.waitUntil {
      host.pending.link == nil && host.editor(text: "A real note") != nil
        && host.model.editors[first.id] == nil
    }
    #expect(host.model.state.selectedID == "kept")

    await host.model.open(.new)
    let second = try #require(host.model.visibleFile?.nextDraft)
    try await host.waitUntil { host.editor(text: "")?.isFirstResponder == true }
    try await host.waitForKeyboard(visible: true)
    host.returnToLibrary()
    try await host.waitUntil { host.isLibraryVisible && host.model.loadedFile == nil }
    let stored = try await fixture.store.drafts(accountID: fixture.account.id).map(\.id)
    #expect(!stored.contains(first.id) && !stored.contains(second.id))
    #expect(fixture.publishes.isEmpty)
  }

  @Test(arguments: [true, false])
  func returningToLibraryPublishesTheOutgoingNoteAndKeepsItsEditor(autosave: Bool) async throws {
    let fixture = try await ModelFixture(autosave: autosave) {
      $0.addGist(id: "a", description: "Current", files: ["README.md": "Current source"])
    }
    let host = try await NavigationHost(fixture: fixture, sizeClass: .compact)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Current source") != nil }
    let editor = try #require(host.editor(text: "Current source"))
    editor.becomeFirstResponder()
    editor.selectedRange = .init(location: 0, length: 0)
    let typed = ContinuousClock.now
    editor.insertText("Local ")
    try await host.waitUntil {
      host.model.drafts.first { $0.gistID == "a" }?.text == "Local Current source"
    }
    host.returnToLibrary()
    try await host.waitUntil { fixture.remote("a", "README.md") == "Local Current source" }
    // Autosave waits five quiet seconds after typing, so a publish before then came from leaving.
    if autosave { #expect(ContinuousClock.now - typed < .seconds(5)) }
    try await host.waitUntil { host.isLibraryVisible }
    #expect(fixture.publishes == ["PATCH /gists/a"])
    #expect(host.model.state.selectedID == nil)
    #expect(!editor.isFirstResponder)
    let selection = editor.selectedRange
    host.pending.link = .gist(id: "a", filename: nil)
    try await host.waitUntil {
      host.pending.link == nil && host.editor(text: "Local Current source") === editor
        && !host.isLibraryVisible
    }
    #expect(editor.selectedRange == selection)
  }

  @Test func switchingNotesMidCompositionKeepsAndPublishesTheComposedText() async throws {
    let fixture = try await ModelFixture(autosave: false) {
      $0.addGist(id: "a", description: "First note", files: ["README.md": "First note source"])
      $0.addGist(id: "b", description: "Second note", files: ["README.md": "Second note source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    host.model.open(rowID: "a")
    try await host.waitUntil { host.editor(text: "First note source") != nil }
    let first = try #require(host.editor(text: "First note source"))
    try #require(first.becomeFirstResponder())
    first.selectedRange = NSRange(location: 0, length: 0)
    first.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
    try #require(first.markedTextRange != nil)
    host.model.open(rowID: "b")
    try await host.waitUntil { host.editor(text: "Second note source") != nil }
    #expect(first.markedTextRange == nil)
    #expect(first.text == "にほんごFirst note source")
    try await host.waitUntil { fixture.remote("a", "README.md") == "にほんごFirst note source" }
    #expect(fixture.publishes == ["PATCH /gists/a"])
  }

  @Test func startingTodayFocusesTheCaretAfterItsDurableInitialContent() async throws {
    let fixture = try await ModelFixture()
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.today())
    let draft = try #require(host.model.visibleFile?.nextDraft)
    #expect(!draft.text.isEmpty)
    try await host.waitUntil { host.editor(text: draft.text)?.isFirstResponder == true }
    let editor = try #require(host.editor(text: draft.text))
    #expect(editor.selectedRange == NSRange(location: draft.text.utf16.count, length: 0))
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aColdLinkWaitsForRestorationAndOpensTheExactFile() async throws {
    let fixture = try await ModelFixture {
      $0.addGist(
        id: "b", description: "Routed note",
        files: ["README.md": "Text", "Ideas.md": "Routed file source"])
    }
    let pending = PendingLink()
    pending.link = .gist(id: "b", filename: "Ideas.md")
    let host = try await NavigationHost(fixture: fixture, pending: pending)
    defer { await host.close() }
    try await host.waitUntil {
      pending.link == nil && host.editor(text: "Routed file source") != nil
    }
    #expect(host.model.loadedFile?.filename == "Ideas.md")
    #expect(host.model.loadedFile?.gist?.id == "b")
  }

  /// A widget's Today opens on a folded phone at a cold launch without waiting for GitHub: at once
  /// when you've written in it on this iPhone, and behind its placeholder while GitHub stages it.
  @Test(arguments: [true, false])
  func aColdTodayLinkOpensWithoutWaitingForGitHub(writtenOnThisIPhone: Bool) async throws {
    let today = DailyNote.filename()
    let fixture = try await ModelFixture {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
    }
    var text = "# \(today.dropLast(3))\n\n"
    if writtenOnThisIPhone {
      await fixture.model.start()
      text = "Written on this iPhone"
      _ = try await fixture.stageEdit(gistID: "daily", filename: today, text: text)
    }
    let github = fixture.hold("GET /gists")
    let pending = PendingLink()
    pending.link = .today
    let host = try await NavigationHost(
      fixture: fixture, model: fixture.relaunch(), pending: pending, sizeClass: .compact,
      waitsForStart: false)
    defer {
      github.open()
      await host.close()
    }
    try await github.arrival()
    try await host.waitUntil { !host.isLibraryVisible }
    if !writtenOnThisIPhone { github.open() }
    try await host.waitUntil {
      pending.link == nil && host.model.visibleFile?.filename == today
        && host.editor(text: text)?.isFirstResponder == true
    }
  }

  /// Opening early doesn't mean deciding from a stale library: today started on the web since
  /// the last launch opens from GitHub while the launch's refresh is still out.
  @Test func aColdTodayLinkOpensTodayFromTheWebOverAStaleLibrary() async throws {
    let today = DailyNote.filename()
    let fixture = try await ModelFixture(
      lastOpened: .gist(id: "a", filename: "README.md")
    ) {
      $0.addGist(
        id: "daily", description: DailyNote.gistDescription,
        files: [DailyNote.filename(date: .now - 86_400): "- [x] Yesterday's task\n"])
      $0.addGist(id: "a", description: "Last opened", files: ["README.md": "Last opened"])
    }
    await fixture.model.start()
    fixture.server.edit("daily", files: [today: "Started on the web"])
    let refresh = fixture.hold("GET /gists/starred")
    let pending = PendingLink()
    pending.link = .today
    let host = try await NavigationHost(
      fixture: fixture, model: fixture.relaunch(), pending: pending, sizeClass: .compact,
      waitsForStart: false)
    defer {
      refresh.open()
      await host.close()
    }
    try await refresh.arrival()
    try await host.waitUntil {
      pending.link == nil && host.model.visibleFile?.filename == today
        && host.editor(text: "Started on the web") != nil
    }
  }

  @Test func aNewGistLinkOpensABlankNoteReadyToWrite() async throws {
    let fixture = try await ModelFixture {
      $0.addGist(id: "a", description: "Existing", files: ["README.md": "Existing source"])
    }
    let pending = PendingLink()
    pending.link = .newGist
    let host = try await NavigationHost(fixture: fixture, pending: pending)
    defer { await host.close() }
    try await host.waitUntil { pending.link == nil && host.editor(text: "")?.isFirstResponder == true }
    let draft = try #require(host.model.visibleFile?.nextDraft)
    #expect(!host.model.drafts.contains { $0.id == draft.id })
    #expect(host.model.visibleFile?.gist == nil)
    #expect(fixture.publishes.isEmpty)
  }

  @Test func aFailedOpenShowsItsOwnTitleAndRetryInsteadOfThePreviousEditor() async throws {
    let fixture = try await ModelFixture {
      $0.addGist(id: "a", description: "Previous", files: ["README.md": "Previous source"])
      $0.addGist(
        id: "b", description: "Requested",
        files: ["README.md": "Text", "Other.md": "Retried source"])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "Previous source") != nil }
    fixture.fail("GET /gists/b")
    await host.model.open(.gist(id: "b", filename: "Other.md", rowID: "result-b"))
    try await host.waitUntil {
      host.descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title }.contains("Requested")
    }
    #expect(host.editor(text: "Previous source") == nil)
    fixture.restore()
    try await host.model.open(#require(host.model.opening).request)
    try await host.waitUntil { host.editor(text: "Retried source") != nil }
    #expect(accessibilityElement("note-open-retry", in: host.window) == nil)
    #expect(host.model.loadedFile?.gist?.id == "b")
    #expect(host.model.state.selectedID == "b")
    #expect(host.model.loadedFile?.filename == "Other.md")
  }

  @Test func sourceIntelligenceOpensTheLiveSheetForTheRetainedEditor() async throws {
    let fixture = try await ModelFixture(autosave: false) {
      $0.addGist(
        id: "a", description: "A retained thought", files: ["README.md": "A little room to think."])
    }
    let host = try await NavigationHost(fixture: fixture)
    defer { await host.close() }
    await host.model.open(.gist(id: "a"))
    try await host.waitUntil { host.editor(text: "A little room to think.") != nil }
    let editor = try #require(host.editor(text: "A little room to think."))
    editor.becomeFirstResponder()
    try await host.waitUntil { editor.isFirstResponder }
    let selection = NSRange(location: 2, length: 6)
    editor.selectedRange = selection
    let accessory = try #require(editor.inputAccessoryView)
    let entry = try #require(
      host.descendants(of: accessory).compactMap { $0 as? UIButton }.first {
        $0.accessibilityIdentifier == "editor-intelligence"
      })
    #expect(entry.isEnabled)
    entry.performPrimaryAction()
    let root = try #require(host.window.rootViewController)
    try await host.waitUntil { intelligencePrompt(presentedOver: root) != nil }
    #expect(!editor.isFirstResponder)
    #expect(editor.selectedRange == selection)
    #expect(host.editor(text: "A little room to think.") === editor)
    #expect(fixture.publishes.isEmpty)
  }
}

/// The app's root view in a real window, around a fixture library.
@MainActor
private struct NavigationHost {
  let model: GistPadModel
  let window: UIWindow
  let pending: PendingLink
  let layout: LayoutPreferences
  private let suite: String
  private let previousWindow: UIWindow?

  init(
    fixture: ModelFixture, model: GistPadModel? = nil, pending: PendingLink = PendingLink(),
    sizeClass: UIUserInterfaceSizeClass? = nil, mode: FileMode = .edit, waitsForStart: Bool = true
  ) async throws {
    self.model = model ?? fixture.model
    self.pending = pending
    suite = "RootView-\(UUID())"
    layout = LayoutPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    layout.select(mode)
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previousWindow = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    let sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds
    // A compact host is a phone even when the simulator is an open Duo.
    let width: CGFloat =
      switch sizeClass {
      case .regular: 1180
      case .compact: min(sceneBounds.width, 440)
      default: sceneBounds.width
      }
    window.frame = CGRect(
      origin: sceneBounds.origin, size: CGSize(width: width, height: sceneBounds.height))
    if let sizeClass { window.traitOverrides.horizontalSizeClass = sizeClass }
    window.rootViewController = UIHostingController(
      rootView: RootView(model: self.model, layout: layout, pending: pending))
    window.makeKeyAndVisible()
    guard waitsForStart else { return }
    let model = self.model
    try await waitUntil {
      model.phase == .ready && model.gistCache != nil
    }
  }

  var descendants: [UIView] {
    descendants(of: window)
  }

  func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  func editor(text: String) -> UITextView? {
    descendants.compactMap { $0 as? UITextView }.first { $0.text == text && $0.window === window }
  }

  /// The file's Edit, Preview (and Split, when wide) control.
  var picker: UISegmentedControl? {
    descendants.compactMap { $0 as? UISegmentedControl }.last
  }

  /// Pops the pushed file the way the system back button does on iPhone.
  func returnToLibrary() {
    descendants.lazy.compactMap { $0.next as? UINavigationController }
      .first { $0.viewControllers.count > 1 }?
      .popViewController(animated: false)
  }

  var isLibraryVisible: Bool {
    let bars = descendants.compactMap { $0 as? UINavigationBar }.filter {
      $0.topItem?.title == "GistPad" && isVisible($0)
    }
    for bar in bars {
      let frame = bar.convert(bar.bounds, to: window)
      let viewport = window.bounds.inset(by: window.safeAreaInsets)
      let point = CGPoint(
        x: frame.intersection(viewport).midX, y: max(viewport.minY, frame.maxY) + 44)
      guard viewport.contains(point) else { continue }
      var hit = window.hitTest(point, with: nil)
      while let view = hit {
        if view is UICollectionView || view is UITableView { return true }
        hit = view.superview
      }
    }
    return false
  }

  func isVisible(_ view: UIView) -> Bool {
    guard view.window === window, !view.bounds.isEmpty else { return false }
    var ancestor: UIView? = view
    while let current = ancestor {
      if current.isHidden || current.alpha < 0.01 { return false }
      ancestor = current.superview
    }
    return window.bounds.insetBy(dx: -0.5, dy: -0.5)
      .contains(view.convert(view.bounds, to: window))
  }

  private var keyboardFrame: CGRect {
    guard let view = window.rootViewController?.view else { return .null }
    return view.convert(view.keyboardLayoutGuide.layoutFrame, to: window)
  }

  func waitForKeyboard(visible: Bool, resigning: Bool = false) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var previous: CGRect?
    var stableSince = ContinuousClock.now
    while ContinuousClock.now < deadline {
      if resigning { window.endEditing(true) }
      window.rootViewController?.view.layoutIfNeeded()
      let frame = keyboardFrame
      let matches = visible
        ? frame.height > 100
          && window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
        : !frame.isNull && frame.height <= window.safeAreaInsets.bottom + 1
      if matches {
        if previous == frame {
          if ContinuousClock.now - stableSince >= .milliseconds(350) { return }
        } else {
          stableSince = ContinuousClock.now
          previous = frame
        }
      } else {
        previous = nil
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(
      "The real keyboard did not settle \(visible ? "on screen" : "off screen"): \(keyboardFrame).")
    throw HostError.presentationTimedOut
  }

  func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation, _ predicate: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        Attachment.record(
          """
          phase: \(model.phase)
          selected: \(String(describing: model.state.selectedID))
          loaded: \(String(describing: model.loadedFile?.id))
          presented: \(String(describing: model.visibleFile?.id))
          opening: \(String(describing: model.opening))
          error: \(String(describing: model.openError))
          link: \(String(describing: pending.link))
          library visible: \(isLibraryVisible)
          editors: \(descendants.compactMap { ($0 as? UITextView)?.text })
          titles: \(descendants.compactMap { ($0 as? UINavigationBar)?.topItem?.title })
          """, named: "navigation-timeout.txt")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "navigation-timeout.png", as: .png)
        Issue.record(
          "The mounted library did not reach its expected presentation.",
          sourceLocation: sourceLocation)
        throw HostError.presentationTimedOut
      }
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func close() async {
    window.rootViewController?.dismiss(animated: false)
    // A closing sheet hands focus back to the file it came from, a beat after it's gone.
    do {
      try await waitForKeyboard(visible: false, resigning: true)
    } catch {
      Issue.record(error, "Navigation host teardown did not finish dismissing its keyboard.")
    }
    if let root = window.rootViewController {
      func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
          + (controller.presentedViewController.map(controllers) ?? [])
      }
      do {
        try await waitUntil { controllers(root).allSatisfy { $0.transitionCoordinator == nil } }
      } catch {
        Issue.record(error, "Navigation host teardown interrupted a native transition.")
      }
    }
    window.isHidden = true
    window.rootViewController = nil
    previousWindow?.makeKeyAndVisible()
    UserDefaults.standard.removePersistentDomain(forName: suite)
  }

  private enum HostError: Error { case presentationTimedOut }
}
