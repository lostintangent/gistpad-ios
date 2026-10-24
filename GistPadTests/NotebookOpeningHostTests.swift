import GistPadInterface
import GistPadSync
import Observation
import SwiftUI
import Testing
import UIKit
import WebKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct NotebookOpeningHostTests {
  @Test func uncachedOpeningWaitsBeforeShowingNativeProgress() async throws {
    let host = try Host()
    defer { host.close() }
    try await host.waitUntil { host.state.appearedAt != nil }
    let appeared = try #require(host.state.appearedAt)
    #expect(appeared.duration(to: .now) < .milliseconds(300))
    #expect(host.progress == nil)
    try await host.waitUntil { host.progress != nil }
    #expect(appeared.duration(to: .now) >= .milliseconds(350))
    #expect(host.progress?.isAnimating == true)
    let bar = try #require(host.nativeViews.compactMap { $0 as? UINavigationBar }.last)
    #expect(bar.topItem?.title == "Selected note")
    #expect(!host.nativeViews.contains { $0 is UITextView && $0.isFirstResponder })
  }

  @Test(arguments: ["# Saved words\n\nAvailable offline.", ""])
  func cachedWordsIncludingAnEmptyFileNeverWaitForProgress(text: String) async throws {
    let host = try Host(document: cachedDocument(text: text))
    defer { host.close() }
    try await host.waitUntil { host.cachedPreview != nil }
    #expect(host.progress == nil)
    try await Task.sleep(for: .milliseconds(450))
    #expect(host.progress == nil)
    let webView = try #require(host.cachedPreview)
    try await host.waitUntil {
      webView.url != nil && !webView.isLoading
    }
    if !text.isEmpty {
      let deadline = ContinuousClock.now + .seconds(5)
      var body = try await webView.evaluateJavaScript("document.body.textContent") as? String
      while body?.contains("Saved words") != true, .now < deadline {
        try await Task.sleep(for: .milliseconds(20))
        body = try await webView.evaluateJavaScript("document.body.textContent") as? String
      }
      #expect(body?.contains("Saved words") == true)
    }
  }

  @Test func changingRequestsAndReceivingContentCancelTheOldDelay() async throws {
    let host = try Host()
    defer { host.close() }
    try await host.waitUntil { host.state.appearedAt != nil }
    try await Task.sleep(for: .milliseconds(200))
    host.state.requestID = "replacement"
    host.state.appearedAt = nil
    try await host.waitUntil { host.state.appearedAt != nil }
    try await Task.sleep(for: .milliseconds(200))
    #expect(host.progress == nil)
    try await host.waitUntil { host.progress != nil }
    host.state.document = try cachedDocument(text: "# Ready now")
    try await host.waitUntil { host.cachedPreview != nil }
    #expect(host.progress == nil)
    try await Task.sleep(for: .milliseconds(400))
    #expect(host.progress == nil)
  }

  @Test func completingBeforeTheDelayNeverFlashesProgressAfterward() async throws {
    let host = try Host()
    defer { host.close() }
    try await host.waitUntil { host.state.appearedAt != nil }
    host.state.document = try cachedDocument(text: "# Already here")
    try await host.waitUntil { host.cachedPreview != nil }
    #expect(host.progress == nil)
    try await Task.sleep(for: .milliseconds(450))
    #expect(host.progress == nil)
  }

  private func cachedDocument(text: String) throws -> NotebookDocument {
    let payload: [String: Any] = [
      "id": "opening-cached", "description": "Selected note", "public": false,
      "updated_at": "2026-10-24T00:00:00Z", "created_at": "2026-10-23T00:00:00Z",
      "files": ["README.md": ["filename": "README.md", "content": text]],
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let gist = try decoder.decode(
      Gist.self, from: JSONSerialization.data(withJSONObject: payload))
    return NotebookDocument(
      accountID: UUID(), gist: gist, filename: "README.md", text: text,
      chrome: .init(
        title: "Selected note", files: [.init(id: "README.md", filename: "README.md")],
        selectedFileID: "README.md"))
  }

  @MainActor @Observable
  fileprivate final class State {
    var requestID = "first"
    var document: NotebookDocument?
    @ObservationIgnored var appearedAt: ContinuousClock.Instant?
  }

  @MainActor
  private final class Host {
    let window: UIWindow
    let state = State()
    private let previous: UIWindow?

    init(document: NotebookDocument? = nil) throws {
      let scene = try #require(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      previous = scene.windows.first(where: \.isKeyWindow)
      state.document = document
      window = UIWindow(windowScene: scene)
      let state = state
      window.rootViewController = UIHostingController(
        rootView: NavigationStack {
          OpeningFixture(state: state)
        })
      window.makeKeyAndVisible()
    }

    var nativeViews: [UIView] { descendants(window) }
    var cachedPreview: WKWebView? {
      nativeViews.compactMap { $0 as? WKWebView }.first {
        $0.window === window && !$0.bounds.isEmpty
      }
    }
    var progress: UIActivityIndicatorView? {
      nativeViews.compactMap { $0 as? UIActivityIndicatorView }.first { !$0.isHidden && $0.alpha > 0 }
    }

    func close() {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }

    func waitUntil(
      sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition(), .now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        window.layoutIfNeeded()
      }
      if !condition() {
        Attachment.record(
          nativeViews.map {
            "\(type(of: $0)): \($0.accessibilityIdentifier ?? "") / \($0.accessibilityLabel ?? "")"
          }.joined(separator: "\n"), named: "opening-native-accessibility.txt")
      }
      try #require(condition(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
  }

  private struct OpeningFixture: View {
    let state: State

    var body: some View {
      NotebookOpeningView(title: "Selected note", document: state.document)
        .onAppear { state.appearedAt = .now }
        .id(state.requestID)
    }
  }
}
