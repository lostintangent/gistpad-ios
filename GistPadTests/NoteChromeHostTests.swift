import GistPadInterface
import SwiftUI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct NoteChromeHostTests {
  @Test(arguments: [1, 2])
  func onlyMultiFileNotesHaveATitleMenuAndItContainsOnlyFileCommands(fileCount: Int) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    var actions = NoteActions()
    actions.rename = {}
    actions.renameFile = {}
    actions.addFile = {}
    actions.selectFile = { _ in }
    let files = [
      NoteFile(id: "README.md", filename: "README.md"),
      NoteFile(id: "Ideas.md", filename: "Ideas.md"),
    ]
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        NoteScreen(
          document: .init(
            title: "A note with files", files: Array(files.prefix(fileCount)),
            selectedFileID: "README.md", isAutoSaveEnabled: true),
          mode: .constant(.reading), saveState: .savedToGitHub, actions: actions
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      })
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .milliseconds(250))
    let navigationBar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let item = try #require(navigationBar.topItem)
    if fileCount == 1 {
      #expect(item.titleMenuProvider == nil)
    } else {
      let menu = try #require(item.titleMenuProvider?([]))
      let titles = menuTitles(menu)
      #expect(titles.contains("README.md"))
      #expect(titles.contains("Ideas.md"))
      #expect(titles.contains("Rename File…"))
      #expect(titles.contains("Add File…"))
      #expect(!titles.contains("Rename Note…"))
    }
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    Attachment.record(image, named: "note-resting-\(fileCount)-files.png", as: .png)
  }

  @Test(arguments: [NoteMode.source, .reading])
  func onlyTheModePickerHidesItsSharedToolbarBackground(mode: NoteMode) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    var actions = NoteActions()
    actions.save = {}
    actions.find = {}
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        NoteScreen(
          document: .init(
            title: "One native capsule", files: [.init(id: "README.md", filename: "README.md")],
            selectedFileID: "README.md", isAutoSaveEnabled: false),
          mode: .constant(mode), saveState: .unsaved, actions: actions
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      })
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(300))
    let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
    let navigation = try #require(bar.topItem)
    let items = navigation.trailingItemGroups.flatMap(\.barButtonItems)
      + (navigation.pinnedTrailingGroup?.barButtonItems ?? [])
    #expect(items.filter(\.hidesSharedBackground).count == 1)
    #expect(items.filter { !$0.hidesSharedBackground }.count >= 2)
  }

  @Test(
    arguments: [false, true],
    [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func regularWidthModePickerKeepsItsNativeIdealSize(
    allowsSplit: Bool, category: UIContentSizeCategory
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
    window.traitOverrides.horizontalSizeClass = .regular
    window.traitOverrides.preferredContentSizeCategory = category
    var actions = NoteActions()
    actions.find = {}
    window.rootViewController = UIHostingController(
      rootView: NavigationStack {
        NoteScreen(
          document: .init(
            title: "A note", files: [.init(id: "README.md", filename: "README.md")],
            selectedFileID: "README.md"),
          mode: .constant(allowsSplit ? .split : .reading),
          saveState: .savedToGitHub, actions: actions, allowsSplit: allowsSplit
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      }
      .environment(\.horizontalSizeClass, .regular))
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    try await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let picker = try #require(descendants(window).compactMap { $0 as? UISegmentedControl }.first)
    let ideal = picker.intrinsicContentSize
    let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(
      for: 48, compatibleWith: window.traitCollection)
    let initialWidth = picker.bounds.width
    #expect(ideal.width > 0)
    #expect(abs(picker.bounds.width - max(ideal.width, minimum * CGFloat(picker.numberOfSegments))) <= 1)
    #expect(!picker.apportionsSegmentWidthsByContent)
    #expect(picker.bounds.height >= 44)
    #expect(picker.numberOfSegments == (allowsSplit ? 3 : 2))
    #expect(window.traitCollection.preferredContentSizeCategory == category)
    #expect(window.bounds.contains(picker.convert(picker.bounds, to: window)))
    for appearance: UIUserInterfaceStyle in [.dark, .light] {
      window.overrideUserInterfaceStyle = appearance
      try await Task.sleep(for: .milliseconds(300))
      window.layoutIfNeeded()
      #expect(abs(picker.bounds.width - initialWidth) <= 1)
    }
  }

  @Test(
    arguments: ["README.md", "readme.md", "ReadMe.MD", "Ideas.md"],
    [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func nativeHeaderOmitsReadmeAndGivesOtherFilesBreathingRoom(
    filename: String, category: UIContentSizeCategory
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.traitOverrides.preferredContentSizeCategory = category
    let title = "A place for good ideas"
    func header(_ filename: String) -> some View {
      var actions = NoteActions()
      actions.selectFile = { _ in }
      return NavigationStack {
        NoteScreen(
          document: .init(
            title: title,
            files: [
              .init(id: "readme", filename: "README.md"),
              .init(id: "selected", filename: filename),
            ], selectedFileID: "selected"),
          mode: .constant(.reading), saveState: .savedToGitHub, actions: actions
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      }
    }
    let host = UIHostingController(rootView: header(filename))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    for selected in [filename, filename == "Ideas.md" ? "README.md" : "Ideas.md", filename] {
      host.rootView = header(selected)
      try await Task.sleep(for: .milliseconds(300))
      window.layoutIfNeeded()
      let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
      let item = try #require(bar.topItem)
      #expect(item.title == title)
      #expect(item.titleMenuProvider != nil)
      let labels = descendants(bar).compactMap { $0 as? UILabel }
      let fileLabel = labels.first { $0.accessibilityIdentifier == "note-header-filename" }
      if selected.caseInsensitiveCompare("README.md") == .orderedSame {
        #expect(item.subtitle?.isEmpty != false)
        #expect(item.subtitleView == nil)
        #expect(fileLabel == nil)
      } else {
        let fileLabel = try #require(fileLabel)
        let titleLabel = try #require(labels.first { $0.text == title })
        let fileFrame = fileLabel.convert(fileLabel.bounds, to: window)
        let titleFrame = titleLabel.convert(titleLabel.bounds, to: window)
        let minimumGap = UIFontMetrics(forTextStyle: .body).scaledValue(
          for: 4, compatibleWith: fileLabel.traitCollection)
        #expect(fileLabel.text == selected)
        #expect(fileFrame.minY - titleFrame.maxY >= minimumGap - 0.5)
        #expect(window.bounds.contains(fileFrame))
        #expect(fileLabel.adjustsFontForContentSizeCategory)
      }
    }
  }

  @Test(arguments: [CGFloat(466), 951], [UIContentSizeCategory.large, .accessibilityExtraLarge])
  func longTitlesYieldToTheUncompressedModePicker(
    width: CGFloat, category: UIContentSizeCategory
  ) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame.size.width = width
    let regular = width > 640
    window.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
    window.traitOverrides.preferredContentSizeCategory = category
    let titles = [
      "A note",
      "A very long notebook title that must yield its space to the complete editing controls while leaving every reading, writing and navigation action intact",
      "💔 OSS Maintainers: A Three-Part Tragedy",
    ]
    func screen(_ title: String) -> some View {
      var actions = NoteActions()
      actions.find = {}
      return NavigationStack {
        NoteScreen(
          document: .init(
            title: title, files: [.init(id: "README.md", filename: "README.md")],
            selectedFileID: "README.md"),
          mode: .constant(.source), saveState: .savedToGitHub,
          actions: actions, allowsSplit: regular
        ) {
          Text("Source")
        } preview: {
          Text("Preview")
        }
      }
      .environment(\.horizontalSizeClass, regular ? .regular : .compact)
    }
    let host = UIHostingController(rootView: screen(titles[0]))
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      previous?.makeKeyAndVisible()
    }
    var baselineWidth: CGFloat?
    for title in titles {
      host.rootView = screen(title)
      try await Task.sleep(for: .milliseconds(300))
      window.layoutIfNeeded()
      let picker = try #require(descendants(window).compactMap { $0 as? UISegmentedControl }.first)
      let minimum = UIFontMetrics(forTextStyle: .body).scaledValue(
        for: 48, compatibleWith: window.traitCollection)
      #expect(abs(picker.bounds.width - max(
        picker.intrinsicContentSize.width, minimum * CGFloat(picker.numberOfSegments))) <= 1)
      if let baselineWidth {
        #expect(abs(picker.bounds.width - baselineWidth) <= 1)
      } else {
        baselineWidth = picker.bounds.width
      }
      let pickerFrame = picker.convert(picker.bounds, to: window)
      #expect(window.bounds.contains(pickerFrame))
      var ancestor = picker.superview
      while let view = ancestor {
        if view.clipsToBounds || view.layer.masksToBounds {
          #expect(view.bounds.insetBy(dx: -1, dy: -1).contains(
            picker.convert(picker.bounds, to: view)))
        }
        ancestor = view.superview
      }
      let bar = try #require(descendants(window).compactMap { $0 as? UINavigationBar }.last)
      #expect(bar.topItem?.title == title)
      if title != titles[0] {
        let label = try #require(descendants(bar).compactMap { $0 as? UILabel }.first { $0.text == title })
        if title == titles[1] || width == 466 {
          #expect(label.bounds.width < label.intrinsicContentSize.width)
        }
        #expect(label.numberOfLines == 1)
        #expect(label.convert(label.bounds, to: window).maxX <= pickerFrame.minX + 1)
      }
      for appearance: UIUserInterfaceStyle in [.light, .dark] {
        window.overrideUserInterfaceStyle = appearance
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(
          image,
          named: "mode-picker-\(Int(width))-\(category.rawValue)-\(title == titles[2] ? "emoji" : title == titles[1] ? "long" : "short")-\(appearance == .dark ? "Dark" : "Light").png",
          as: .png)
      }
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func menuTitles(_ menu: UIMenu) -> [String] {
    menu.children.flatMap { item in
      if let menu = item as? UIMenu { return [menu.title] + menuTitles(menu) }
      return [(item as? UIAction)?.title].compactMap { $0 }
    }
  }

}
