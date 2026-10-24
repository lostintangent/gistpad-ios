import Observation
import SwiftUI
import Testing
import UIKit

@testable import GistPadInterface

@Suite(.serialized)
@MainActor
struct LibraryToolbarHostTests {
  @Test func searchProgressWaits400MillisecondsAndKeepsTheSameTarget() async throws {
    let host = try await SearchHost()
    defer { host.close() }
    let original = host.frame
    let started = ContinuousClock.now
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!host.hasSpinner)
    try await host.waitUntil { host.hasSpinner }
    #expect(started.duration(to: .now) >= .milliseconds(400))
    #expect(host.frame == original)
    host.model.state = .idle
    try await host.waitUntil { !host.hasSpinner }
    #expect(host.frame == original)
    #expect(host.model.searches == 0)
  }

  @Test func quickAndSupersededChecksCannotLeaveSearchProgressBehind() async throws {
    let host = try await SearchHost()
    defer { host.close() }
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(150))
    host.model.state = .idle
    try await Task.sleep(for: .milliseconds(450))
    #expect(!host.hasSpinner)
    host.model.state = .checking(operation: "Checking GitHub")
    try await Task.sleep(for: .milliseconds(250))
    host.model.state = .checking(operation: "Refreshing account")
    try await Task.sleep(for: .milliseconds(200))
    #expect(!host.hasSpinner)
    try await host.waitUntil { host.hasSpinner }
    host.model.state = .problem(.init(
      heading: "Couldn't update your gists", message: "The connection is unavailable.",
      recoveryTitle: "Retry"))
    try await host.waitUntil { !host.hasSpinner }
    #expect(host.model.searches == 0)
  }
}

@Observable
@MainActor
private final class SearchHostModel {
  var state: GitHubStatusState = .idle
  var searches = 0
}

@MainActor
private struct SearchHostView: View {
  @Bindable var model: SearchHostModel

  var body: some View {
    NavigationStack {
      Text("Synthetic notebook")
        .toolbar {
          ToolbarSpacer(.flexible, placement: .bottomBar)
          ToolbarItem(placement: .bottomBar) {
            LibraryView.SearchButton { model.searches += 1 }
          }
        }
        .modifier(LibraryView.SearchProgressModifier(state: model.state))
    }
  }
}

@MainActor
private final class SearchHost {
  let model = SearchHostModel()
  let window: UIWindow
  private let previous: UIWindow?

  init() async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    previous = scene.windows.first(where: \.isKeyWindow)
    window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(
      rootView: SearchHostView(model: model).transaction { $0.disablesAnimations = true })
    window.makeKeyAndVisible()
    try await waitUntil { !self.frame.isEmpty }
  }

  var frame: CGRect {
    guard let marker = marker("capture-frame-library-search", in: window) else { return .zero }
    return marker.convert(marker.bounds, to: window)
  }

  var hasSpinner: Bool {
    guard let marker = marker("capture-frame-library-search-progress", in: window),
      marker.window === window, !marker.bounds.isEmpty
    else { return false }
    var ancestor: UIView? = marker
    while let view = ancestor {
      if view.isHidden || view.alpha <= 0 || view.layer.opacity <= 0 { return false }
      ancestor = view.superview
    }
    return marker.convert(marker.bounds, to: window).intersects(window.bounds)
  }

  private var spinnerVisibility: String {
    var ancestor = marker("capture-frame-library-search-progress", in: window)
    var descriptions: [String] = []
    while let view = ancestor {
      descriptions.append(
        "\(type(of: view)): hidden=\(view.isHidden), alpha=\(view.alpha), opacity=\(view.layer.opacity), frame=\(view.frame)")
      ancestor = view.superview
    }
    return descriptions.joined(separator: "\n")
  }

  private func marker(_ identifier: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == identifier { return view }
    return view.subviews.lazy.compactMap { self.marker(identifier, in: $0) }.first
  }

  func waitUntil(
    _ ready: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !ready(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(ready(), "\(spinnerVisibility)", sourceLocation: sourceLocation)
  }

  func close() {
    window.isHidden = true
    window.rootViewController = nil
    previous?.makeKeyAndVisible()
  }
}
