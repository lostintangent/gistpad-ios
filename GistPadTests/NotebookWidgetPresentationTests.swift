@_spi(Testing) import GistPadPlatform
import SwiftUI
import Testing
import UIKit
import WidgetKit

@testable import GistPad

@Suite(.serialized)
@MainActor
struct NotebookWidgetPresentationTests {
  @Test(arguments: [
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: false, accessibility: false),
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: true, accessibility: false),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: false, accessibility: false),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: true, accessibility: false),
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: false, accessibility: true),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: true, accessibility: true),
    WidgetPresentation(family: .accessoryRectangular, width: 172, height: 76, dark: true, accessibility: false),
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: false, accessibility: false, empty: true),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: true, accessibility: false, empty: true),
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: true, accessibility: false, state: .locked),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: false, accessibility: false, state: .locked),
    WidgetPresentation(family: .systemSmall, width: 186, height: 186, dark: false, accessibility: true, state: .signedOut),
    WidgetPresentation(family: .systemMedium, width: 398, height: 186, dark: true, accessibility: false, state: .signedOut)
  ])
  func capturesSupportedWidgetPresentations(presentation: WidgetPresentation) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let date = Date(timeIntervalSince1970: 1_792_800_000)
    let snapshot = try presentation.empty
      ? NotebookSystemSnapshot.make(accountID: UUID(), cache: nil, drafts: [], date: date)
      : NotebookSystemSnapshot.preview(date: date)
    var taskSizes: [String: CGSize] = [:]
    var layoutFrames: [String: CGRect] = [:]
    let content = TodayWidgetView(
      snapshot: snapshot, date: date, state: presentation.state, family: presentation.family,
      taskGeometry: { taskSizes[$0] = $1 },
      layoutGeometry: { layoutFrames[$0] = $1 })
      .padding(presentation.family == .accessoryRectangular ? 0 : 16)
      .background(Color(uiColor: .secondarySystemGroupedBackground))
      .environment(\.colorScheme, presentation.dark ? .dark : .light)
      .environment(\.dynamicTypeSize, presentation.accessibility ? .accessibility3 : .large)
      .ignoresSafeArea()
    let host = UIHostingController(rootView: content)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: presentation.width, height: presentation.height)
    window.rootViewController = host
    window.overrideUserInterfaceStyle = presentation.dark ? .dark : .light
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(120))
    host.view.layoutIfNeeded()
    #expect(host.view.bounds.width == presentation.width)
    #expect(host.view.bounds.height == presentation.height)
    if presentation.state == .available, !presentation.empty,
      !(presentation.family == .systemSmall && presentation.accessibility)
    {
      for task in snapshot.today.tasks.prefix(presentation.family == .systemMedium && !presentation.accessibility ? 2 : 1) {
        let taskSize = try #require(taskSizes[task.id])
        #expect(taskSize.height >= 44)
      }
    } else {
      #expect(taskSizes.isEmpty)
    }
    if presentation.family == .systemSmall, !presentation.accessibility {
      let calendar = try #require(layoutFrames["small-calendar"])
      let content = try #require(layoutFrames["small-content"])
      #expect(abs(content.minY - calendar.maxY - 12) < 0.5)
    }
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image,
      named: "widget-\(presentation.family.rawValue)-\(Int(presentation.width))-\(presentation.dark ? "Dark" : "Light")-\(presentation.accessibility ? "AX3" : "Large")-\(presentation.state)-\(presentation.empty ? "Empty" : "Tasks").png",
      as: .png)
  }

  @Test(arguments: [false, true], [false, true])
  func capturesNativeQuickCapture(dark: Bool, accessibility: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let content = Color.clear
      .sheet(isPresented: .constant(true)) {
        AddToTodaySheet()
          .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
      }
    let window = UIWindow(windowScene: scene)
    window.frame = scene.effectiveGeometry.coordinateSpace.bounds
    window.rootViewController = UIHostingController(rootView: content)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.makeKeyAndVisible()
    defer {
      window.endEditing(true)
      window.rootViewController?.dismiss(animated: false)
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKeyAndVisible()
    }
    func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !descendants(window).compactMap({ $0 as? UITextView }).contains(where: {
      $0.window === window && !$0.bounds.isEmpty && $0.isEditable
    }),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    let editor = try #require(descendants(window).compactMap { $0 as? UITextView }.first {
      $0.window === window && !$0.bounds.isEmpty && $0.isEditable
    })
    #expect(editor.bounds.height >= 44)
    window.endEditing(true)
    try await Task.sleep(for: .milliseconds(700))
    window.layoutIfNeeded()
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image, named: "capture-\(dark ? "Dark" : "Light")-\(accessibility ? "AX3" : "Large").png",
      as: .png)
  }
}

struct WidgetPresentation: Sendable {
  let family: WidgetFamily
  let width: CGFloat
  let height: CGFloat
  let dark: Bool
  let accessibility: Bool
  var state: TodayWidgetState = .available
  var empty = false
}
