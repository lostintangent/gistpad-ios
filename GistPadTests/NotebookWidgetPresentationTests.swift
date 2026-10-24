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
    WidgetPresentation(family: .accessoryRectangular, width: 172, height: 76, dark: true, accessibility: false)
  ])
  func capturesSupportedWidgetPresentations(presentation: WidgetPresentation) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let date = Date(timeIntervalSince1970: 1_792_800_000)
    let snapshot = NotebookSystemSnapshot.preview(date: date)
    var taskSizes: [String: CGSize] = [:]
    let content = TodayWidgetView(
      snapshot: snapshot, date: date, state: .available, family: presentation.family,
      taskGeometry: { taskSizes[$0] = $1 })
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
    let task = try #require(snapshot.today.tasks.first)
    let taskSize = try #require(taskSizes[task.id])
    #expect(taskSize.height >= 44)
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    Attachment.record(
      image,
      named: "widget-\(presentation.family.rawValue)-\(Int(presentation.width))-\(presentation.dark ? "Dark" : "Light")-\(presentation.accessibility ? "AX3" : "Large").png",
      as: .png)
  }

  @Test(arguments: [false, true], [false, true])
  func capturesNativeQuickCapture(dark: Bool, accessibility: Bool) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
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
    defer { window.isHidden = true }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while notebookAccessibilityElement("today-capture-input", in: window) == nil,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    _ = try #require(notebookAccessibilityElement("today-capture-input", in: window))
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
}
