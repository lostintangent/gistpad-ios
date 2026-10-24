import GistPadEditor
import GistPadInterface
import Observation
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct GitHubStatusHostTests {
  @Test func backgroundProgressWaitsAtLeast350MillisecondsAndEndsImmediately() async throws {
    let host = try await StatusHost()
    defer { host.close() }
    let started = ContinuousClock.now
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!host.hasSpinner)
    try await host.waitUntil { host.hasSpinner }
    #expect(started.duration(to: .now) >= .milliseconds(350))
    host.model.state = .idle
    try await host.waitUntil { !host.hasSpinner && !host.model.statusMounted }
    #expect(host.model.recoveries == 0)
  }

  @Test func quickAndSupersededChecksCannotLeaveDelayedProgress() async throws {
    let host = try await StatusHost()
    defer { host.close() }
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(150))
    host.model.state = .idle
    try await Task.sleep(for: .milliseconds(300))
    #expect(!host.hasSpinner)
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(200))
    host.model.state = .checking(operation: "Updating from GitHub")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!host.hasSpinner)
    try await host.waitUntil { host.hasSpinner }
    #expect(host.model.recoveries == 0)
    host.model.state = .idle
  }

  @Test(arguments: [false, true], [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func problemLayoutRemainsMountedAcrossRecoveryStatesAndLeavesOnlyWhenIdle(
    dark: Bool, category: UIContentSizeCategory
  ) async throws {
    let host = try await StatusHost(dark: dark, category: category)
    defer { host.close() }
    host.model.state = .problem(problem())
    try await host.waitUntil { host.model.statusMounted && !host.model.statusFrame.isEmpty }
    #expect(host.window.bounds.intersects(host.model.statusFrame))
    host.model.state = .problem(problem(isRecovering: true))
    try await Task.sleep(for: .milliseconds(100))
    #expect(host.model.statusMounted)
    host.model.state = .problem(problem())
    try await Task.sleep(for: .milliseconds(100))
    #expect(host.model.statusMounted)
    #expect(!host.model.statusFrame.isEmpty)
    #expect(host.model.recoveries == 0)
    let image = UIGraphicsImageRenderer(bounds: host.window.bounds).image { _ in
      host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image, named: "github-status-problem-\(dark ? "Dark" : "Light")-\(category.rawValue).png", as: .png)
    host.model.state = .idle
    try await host.waitUntil { !host.model.statusMounted }
  }

  @Test func statusUpdatesPreserveAScrolledEditorsSourceSelectionAndViewport() async throws {
    let source = (1...180).map {
      "Paragraph \($0) leaves enough room for a useful thought and a retained writing position."
    }.joined(separator: "\n\n")
    let host = try await StatusHost(source: source)
    defer { host.close() }
    let session = try #require(host.session)
    let editor = session.textView
    var geometry: [String] = []
    func sourceAtViewportTop() -> Int? {
      let point = CGPoint(
        x: editor.textContainerInset.left + editor.textContainer.lineFragmentPadding,
        y: editor.bounds.minY + editor.adjustedContentInset.top + 1)
      guard let position = editor.closestPosition(to: point) else { return nil }
      return editor.offset(from: editor.beginningOfDocument, to: position)
    }
    func capture(_ stage: String) {
      let viewportSource = sourceAtViewportTop()
      let caret = editor.selectedTextRange.map { editor.caretRect(for: $0.end) } ?? .null
      geometry.append(
        """
        \(stage): offset \(editor.contentOffset), bounds \(editor.bounds), content \(editor.contentSize), \
        insets \(editor.contentInset), adjusted \(editor.adjustedContentInset), \
        textContainer \(editor.textContainer.size), caret \(caret), \
        windowCaret \(editor.convert(caret, to: host.window)), viewportSource \(String(describing: viewportSource)), \
        selected \(editor.selectedRange), font \(editor.font?.pointSize ?? 0), \
        focus \(editor.isFirstResponder), keyboard \(host.keyboardHeight), \
        presented \(host.presented != nil)
        """)
    }
    defer { Attachment.record(geometry.joined(separator: "\n"), named: "status-source-viewport.txt") }
    try #require(editor.becomeFirstResponder())
    try await host.waitUntil {
      editor.isFirstResponder && host.keyboardHeight >= 150
    }
    let selection = (source as NSString).range(of: "Paragraph 140")
    editor.selectedRange = selection
    editor.scrollRangeToVisible(selection)
    try await Task.sleep(for: .milliseconds(350))
    // Offscreen TextKit estimates can change without moving the visible source passage.
    let viewportSource = try #require(sourceAtViewportTop())
    let caret = try #require(editor.selectedTextRange).end
    let writingPosition = editor.convert(editor.caretRect(for: caret), to: host.window)
    let identity = session.viewIdentity
    let canUndo = editor.undoManager?.canUndo
    capture("scrolled")
    let generation = session.generation
    let states: [(String, GitHubStatusState)] = [
      ("attention", .problem(problem())),
      ("recovering", .problem(problem(isRecovering: true))),
      ("unresolved", .problem(problem())),
      ("idle", .idle),
    ]
    for (stage, state) in states {
      host.model.state = state
      try await host.waitUntil { host.model.renderedState == state }
      try await Task.sleep(for: .milliseconds(350))
      capture(stage)
      #expect(session.viewIdentity == identity)
      #expect(editor.selectedRange == selection)
      #expect(session.generation == generation)
      #expect(session.text.utf8.elementsEqual(source.utf8))
      #expect(editor.text.utf8.elementsEqual(source.utf8))
      #expect(editor.undoManager?.canUndo == canUndo)
      #expect(editor.isFirstResponder)
      #expect(sourceAtViewportTop() == viewportSource)
      let restoredCaret = try #require(editor.selectedTextRange).end
      let restoredPosition = editor.convert(editor.caretRect(for: restoredCaret), to: host.window)
      #expect(abs(restoredPosition.minY - writingPosition.minY) <= 1)
      #expect(abs(restoredPosition.minX - writingPosition.minX) <= 1)
    }
    #expect(host.model.recoveries == 0)
  }

  private func problem(isRecovering: Bool = false) -> GitHubStatusProblem {
    .init(
      heading: "Couldn't check for updates",
      message: "A connection could not be established after retrying.",
      recoveryTitle: "Retry", detail: "Your notes on this iPhone are unchanged.",
      isRecovering: isRecovering)
  }
}

@Observable
@MainActor
private final class StatusModel {
  var state: GitHubStatusState = .idle
  var recoveries = 0
  var statusMounted = false
  var statusFrame = CGRect.zero
  var renderedState: GitHubStatusState = .idle

  func recover() {
    guard case .problem(let problem) = state else {
      Issue.record("Recovery requires a presented problem.")
      return
    }
    recoveries += 1
    state = .problem(.init(
      heading: problem.heading, message: problem.message, recoveryTitle: problem.recoveryTitle,
      detail: problem.detail, isRecovering: true))
  }
}

@MainActor
private struct StatusFixture: View {
  @Bindable var model: StatusModel
  var session: DocumentSession?

  var body: some View {
    NavigationStack {
      Group {
        if let session {
          MarkdownEditorView(session: session)
        } else {
          Text("A real page remains in place.")
        }
      }
        .navigationTitle("A note")
        .toolbar {
          if model.state != .idle {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
              GitHubStatusControl(state: model.state, recover: model.recover)
                .onAppear { model.statusMounted = true }
                .onDisappear {
                  model.statusMounted = false
                  model.statusFrame = .zero
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                  model.statusFrame = $0
                }
            }
            .sharedBackgroundVisibility(.hidden)
          }
        }
        .onChange(of: model.state) { _, state in model.renderedState = state }
    }
  }
}

@MainActor
private final class StatusHost {
  let model = StatusModel()
  let window: UIWindow
  let session: DocumentSession?
  private(set) var keyboardHeight: CGFloat = 0
  private let previous: UIWindow?
  private var keyboardObserver: NSObjectProtocol?

  init(
    dark: Bool = false, category: UIContentSizeCategory = .large, source: String? = nil
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previous = scene.windows.first(where: \.isKeyWindow)
    session = source.map { DocumentSession(documentID: "github-status-source", text: $0) }
    window = UIWindow(windowScene: scene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.traitOverrides.preferredContentSizeCategory = category
    window.rootViewController = UIHostingController(
      rootView: StatusFixture(model: model, session: session).personalAccent(savedHex: "#FACC15"))
    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
      else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        self.keyboardHeight = max(0, scene.effectiveGeometry.coordinateSpace.bounds.intersection(frame).height)
      }
    }
    window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(250))
  }

  var presented: UIViewController? { window.rootViewController?.presentedViewController }

  var hasSpinner: Bool {
    descendants(window).compactMap { $0 as? UIActivityIndicatorView }
      .contains { $0.isAnimating && !$0.isHidden && $0.alpha > 0 }
  }

  func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ ready: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      window.layoutIfNeeded()
      if ready() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(
      "The native GitHub status control did not reach the required state.", sourceLocation: sourceLocation)
    throw StatusFailure.timedOut
  }

  func close() {
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    window.rootViewController?.dismiss(animated: false)
    window.endEditing(true)
    window.isHidden = true
    window.rootViewController = nil
    previous?.makeKeyAndVisible()
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}

private enum StatusFailure: Error { case timedOut }
