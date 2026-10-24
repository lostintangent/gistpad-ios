#if DEBUG
import GistPadAppearance
import GistPadEditor
import GistPadInterface
import GistPadSync
import SwiftUI
import UIKit

struct NotebookSurfaceCaptureWorkspace: View {
  let screen: String
  private let captureState: String?
  @State private var path: [String]
  @State private var session = DocumentSession(
    documentID: "note-chrome-capture",
    text: """
      # A place for good ideas

      Some days, all you need is a little room to think.

      Keep the useful things close. Let the rest find their place.

      ## A few things worth keeping

      - A good walk clears more than your head.
      - The best ideas usually start as a sentence.
      - Leave a little space for tomorrow.

      ## Next, something small

      - [x] Make room to write
      - [ ] Follow the thread
      - [ ] See where it goes
      """)
  @State private var mode = NoteMode.reading
  @State private var presentedSheet: CaptureSheet?
  @State private var preferences = Preferences(isAutoSaveEnabled: true, accentColor: "#0EA5E9")
  @State private var selectedTagIDs: Set<String> = ["ideas", "everyday"]
  @State private var readinessError: String?
  @State private var keyboardHeight: CGFloat = 0

  init(screen: String, accent: String? = nil) {
    self.screen = screen
    let arguments = ProcessInfo.processInfo.arguments
    if let index = arguments.firstIndex(of: "--capture-state"),
      arguments.indices.contains(index + 1)
    {
      captureState = arguments[index + 1]
    } else {
      captureState = nil
    }
    _path = State(initialValue: [screen])
    let accent = accent ?? LaunchArguments.captureAccent ?? "#0EA5E9"
    _preferences = State(initialValue: Preferences(isAutoSaveEnabled: true, accentColor: accent))
  }

  static func supports(_ screen: String) -> Bool {
    ["note-chrome", "note-loading", "note-failed", "settings", "settings-signed-out", "tags", "account", "capture-today"]
      .contains(screen)
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Button("A place for good ideas") { path = [screen] }
      }
      .navigationTitle("Library")
      .navigationDestination(for: String.self) { _ in surface }
    }
    .sheet(item: $presentedSheet) { sheet in
      Group {
        switch sheet {
        case .settings:
          settings
        case .tags:
          TagEditor(tags: Self.tags, selectedTagIDs: selectedTagIDs) { edits in
            for edit in edits {
              if case .setMembership(let id, let included) = edit {
                if included { selectedTagIDs.insert(id) } else { selectedTagIDs.remove(id) }
              }
            }
          }
          .captureQuery(tagCaptureQuery)
          .captureEditingTag(
            captureState == "new-tag" ? .init(id: "capture-new-tag", name: "")
              : captureState == "edit-tag" ? Self.tags[0] : nil)
        case .account:
          NotebookAccountSwitchSheet(
            current: "octavia", replacement: "mira", export: { Data("[]".utf8) },
            switchAccount: { presentedSheet = nil }, keepCurrent: { presentedSheet = nil })
        case .captureToday:
          AddToTodaySheet.captureFixture()
        }
      }
      .background { readinessMarker }
      .personalAccent(savedHex: preferences.accentColor)
    }
    .alert(
      "Capture Readiness Failed",
      isPresented: Binding(
        get: { readinessError != nil }, set: { if !$0 { readinessError = nil } })
    ) {
      Button("OK") { readinessError = nil }
    } message: {
      Text(readinessError ?? "")
    }
    .task {
      if screen.hasPrefix("settings") { presentedSheet = .settings }
      if screen == "tags" { presentedSheet = .tags }
      if screen == "account" { presentedSheet = .account }
      if screen == "capture-today" { presentedSheet = .captureToday }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
      guard capturesKeyboard,
        let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
        let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
      else { return }
      keyboardHeight = max(0, scene.effectiveGeometry.coordinateSpace.bounds.intersection(frame).height)
    }
    .personalAccent(savedHex: preferences.accentColor)
  }

  @ViewBuilder
  private var surface: some View {
    Group {
      if screen == "note-loading" {
        NotebookOpeningView(title: "A place for good ideas")
      } else if screen == "note-failed" {
        NotebookFailedOpeningView(
          failure: .init(
            rowID: "fixture", title: "A place for good ideas", gistID: "fixture",
            filename: "README.md", draftID: nil,
            message: NotebookModel.message(for: URLError(.notConnectedToInternet)))
        ) {}
      } else {
        NoteScreen(
          document: chrome, mode: $mode, saveState: captureSaveState, actions: actions
        ) {
          MarkdownEditorView(session: session)
        } preview: {
          SessionPreview(session: session)
        }
      }
    }
    .background {
      if ["note-loading", "note-failed", "note-chrome"].contains(screen) {
        readinessMarker
      }
    }
  }

  private var readinessMarker: some View {
    NotebookSurfaceReadinessMarker(
      requiresKeyboard: screen == "capture-today" && captureState != "error",
      keyboardHeight: keyboardHeight,
      step: captureStep,
      failed: recordCaptureFailure
    ) { window, keyboardHeight, evidence in
      guard let token = captureToken else { return }
      do {
        var metadata: [String: Any] = [
          "screen": screen, "fixture": "native-surfaces", "token": token,
          "state": captureState ?? "resting",
          "accent": preferences.accentColor ?? "",
          "contentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue,
          "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
          "keyboardHeight": keyboardHeight,
          "interactionEvidence": "presentation-only",
        ]
        metadata.merge(evidence.metadata) { _, value in value }
        if screen == "capture-today",
          let writing = TodayCaptureWritingMetrics(window: window, keyboardHeight: keyboardHeight)
        {
          metadata["writingLineCount"] = writing.visibleLineCount
          metadata["writingLineHeight"] = writing.lineHeight
          metadata["writingVisibleHeight"] = writing.visibleHeight
          metadata["captureCharacterCount"] = writing.characterCount
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try data.write(
          to: FileManager.default.temporaryDirectory
            .appendingPathComponent("gistpad-capture-\(token).ready"),
          options: .atomic)
      } catch {
        readinessError = error.localizedDescription
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var captureToken: String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--capture-ready-token"),
      arguments.indices.contains(index + 1),
      UUID(uuidString: arguments[index + 1]) != nil
    else { return nil }
    return arguments[index + 1]
  }

  private func recordCaptureFailure(_ message: String) {
    readinessError = message
    guard let token = captureToken else { return }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "token": token, "screen": screen, "state": captureState ?? "resting",
          "error": message,
        ], options: [.sortedKeys])
      try data.write(
        to: FileManager.default.temporaryDirectory
          .appendingPathComponent("gistpad-capture-\(token).failed"), options: .atomic)
    } catch {
      readinessError = "\(message)\nThe capture failure could not be recorded: \(error.localizedDescription)"
    }
  }

  private var tagCaptureQuery: String {
    switch captureState {
    case "search": "Ideas"
    case "search-empty": "No matching tag"
    default: ""
    }
  }

  private var capturesKeyboard: Bool {
    (screen == "capture-today" && captureState != "error")
      || (screen == "tags" && ["search", "search-empty", "new-tag"].contains(captureState ?? ""))
  }

  private var captureStep: NotebookSurfaceCaptureStep? {
    guard let captureState else { return nil }
    switch (screen, captureState) {
    case ("note-chrome", _): return .menu(captureState)
    case ("tags", "search"): return .tagSearch(query: tagCaptureQuery, expectedTagID: "ideas")
    case ("tags", "search-empty"): return .tagSearch(query: tagCaptureQuery, expectedTagID: nil)
    case ("tags", "new-tag"): return .newTag
    case ("tags", "edit-tag"): return .editTag
    case ("settings", "end"): return .end(requiredID: "settings-sign-out")
    case ("account", "end"): return .end(requiredID: "account-switch-export")
    case ("settings", "sign-out"): return .signOut
    case ("settings", "error"): return .accentError
    case ("settings", "accent-save"): return .accentSave
    case ("tags", _), ("settings", _), ("account", _):
      return .unsupported("\(screen)/\(captureState)")
    default: return nil
    }
  }

  private var chrome: NoteChrome {
    let files = ProcessInfo.processInfo.arguments.contains("--capture-multi-file")
      ? [NoteFile(id: "README.md", filename: "README.md"), .init(id: "Ideas.md", filename: "Ideas.md")]
      : [NoteFile(id: "README.md", filename: "README.md")]
    return .init(
      title: "A place for good ideas", files: files, selectedFileID: "README.md",
      tags: Array(Self.tags.prefix(2)), isAutoSaveEnabled: true)
  }

  private var captureSaveState: NoteSaveState {
    if ProcessInfo.processInfo.arguments.contains("--capture-offline") { return .offline }
    if ProcessInfo.processInfo.arguments.contains("--capture-cloud-failure") {
      return .cloudFailure(message: NotebookModel.message(for: URLError(.notConnectedToInternet)))
    }
    return .savedToGitHub
  }

  private var actions: NoteActions {
    var actions = NoteActions()
    actions.selectFile = { _ in }
    actions.rename = {}
    actions.renameFile = {}
    actions.addFile = {}
    actions.togglePin = {}
    actions.toggleStar = {}
    actions.share = {}
    actions.copyLink = {}
    actions.find = { mode = .source; session.presentFind(replacing: true) }
    actions.tags = { presentedSheet = .tags }
    actions.intelligence = {}
    actions.openInGitHub = {}
    actions.toggleArchive = {}
    actions.delete = {}
    actions.retry = {}
    actions.save = {}
    return actions
  }

  private var settings: some View {
    NotebookSettingsSheet(
      account: screen == "settings-signed-out" ? nil : .init(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        login: "octavia", preferences: preferences),
      savePreference: { key, value in preferences = try preferences.applying(.setBoolean(key, value)) },
      connect: { presentedSheet = .account },
      signOut: { presentedSheet = nil }
    ) {
      let row = PersonalAccentColorRow(savedHex: preferences.accentColor) {
        if captureState == "error" {
          throw NotebookSurfaceCaptureFailure(
            message: NotebookModel.message(for: URLError(.notConnectedToInternet)))
        }
        preferences = try preferences.applying(.setAccentColor($0))
      }
      if ["error", "accent-save"].contains(captureState ?? "") {
        row.capturePendingColor(PersonalAccent(savedHex: "#DB9E47").color)
          .captureError(
            captureState == "error"
              ? NotebookModel.message(for: URLError(.notConnectedToInternet)) : nil)
      } else {
        row
      }
    }
    .captureSignOutConfirmation(captureState == "sign-out")
  }

  private enum CaptureSheet: String, Identifiable {
    case settings, tags, account
    case captureToday = "capture-today"
    var id: Self { self }
  }

  fileprivate static let tags = [
    LibraryTag(id: "everyday", name: "Everyday", colorHex: "#0EA5E9"),
    LibraryTag(id: "ideas", name: "Ideas", colorHex: "#DB9E47"),
    LibraryTag(id: "making", name: "Making things", colorHex: "#6DAD8B"),
    LibraryTag(id: "reading", name: "Reading", colorHex: "#9D89C5"),
    LibraryTag(id: "weekend", name: "Weekend", colorHex: "#D87C8D"),
  ]
}

private struct NotebookSurfaceReadinessMarker: UIViewControllerRepresentable {
  let requiresKeyboard: Bool
  let keyboardHeight: CGFloat
  let step: NotebookSurfaceCaptureStep?
  let failed: @MainActor (String) -> Void
  let ready: @MainActor (UIWindow, CGFloat, NotebookSurfaceCaptureEvidence) -> Void

  func makeUIViewController(context: Context) -> NotebookSurfaceReadinessController {
    NotebookSurfaceReadinessController(
      requiresKeyboard: requiresKeyboard, step: step, failed: failed, ready: ready)
  }

  func updateUIViewController(_ controller: NotebookSurfaceReadinessController, context: Context) {
    controller.keyboardHeight = keyboardHeight
  }
}

private final class NotebookSurfaceReadinessController: UIViewController {
  private let requiresKeyboard: Bool
  private let step: NotebookSurfaceCaptureStep?
  private let failed: @MainActor (String) -> Void
  private let ready: @MainActor (UIWindow, CGFloat, NotebookSurfaceCaptureEvidence) -> Void
  private var readiness: Task<Void, Never>?
  var keyboardHeight: CGFloat = 0

  init(
    requiresKeyboard: Bool, step: NotebookSurfaceCaptureStep?,
    failed: @escaping @MainActor (String) -> Void,
    ready: @escaping @MainActor (UIWindow, CGFloat, NotebookSurfaceCaptureEvidence) -> Void
  ) {
    self.requiresKeyboard = requiresKeyboard
    self.step = step
    self.failed = failed
    self.ready = ready
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard readiness == nil else { return }
    guard let window = view.window else { return }
    window.layoutIfNeeded()
    if let step {
      switch step {
      case .menu(let state):
        guard let menu = NotebookMenuCapture(rawValue: state) else {
          failed("Unsupported native note menu capture: \(state).")
          return
        }
        openMenu(menu, in: window)
      case .unsupported(let state):
        failed("Unsupported native surface capture: \(state).")
      default:
        preparePresentation(step, in: window)
      }
      return
    }
    guard requiresKeyboard else { ready(window, 0, .init()); return }
    readiness = Task { @MainActor in
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      var previousHeight: CGFloat = 0
      var previousWriting: TodayCaptureWritingMetrics?
      var stableSamples = 0
      do {
        while ContinuousClock.now < deadline {
          try Task.checkCancellation()
          guard view.window === window, !window.isHidden else { return }
          window.layoutIfNeeded()
          let height = keyboardHeight
          let writing = TodayCaptureWritingMetrics(window: window, keyboardHeight: height)
          if height >= 150, let writing, writing.visibleLineCount >= 2 {
            stableSamples =
              abs(height - previousHeight) < 0.5 && writing == previousWriting
              ? stableSamples + 1 : 0
            if stableSamples >= 3 { ready(window, height, .init()); return }
          } else {
            stableSamples = 0
          }
          previousWriting = writing
          previousHeight = height
          try await Task.sleep(for: .milliseconds(16))
        }
        failed(
          "The native Today editor needs a settled keyboard and two visible writing lines. "
            + "Keyboard height: \(keyboardHeight), visible lines: \(previousWriting?.visibleLineCount ?? 0).")
      } catch is CancellationError {
        return
      } catch {
        failed(error.localizedDescription)
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    if step?.waitsForChildPresentation != true {
      readiness?.cancel()
      readiness = nil
    }
    super.viewWillDisappear(animated)
  }

  private func preparePresentation(_ step: NotebookSurfaceCaptureStep, in window: UIWindow) {
    readiness = Task { @MainActor in
      do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var activated = false
        var stableSamples = 0
        var previousEvidence: NotebookSurfaceCaptureEvidence?
        while ContinuousClock.now < deadline {
          try Task.checkCancellation()
          guard !window.isHidden else { return }
          window.layoutIfNeeded()
          var evidence = NotebookSurfaceCaptureEvidence()
          var complete = false
          if UIApplication.shared.applicationState == .active {
            switch step {
            case .tagSearch(let query, let expectedTagID):
              if !activated, let control = descendants(window).compactMap({ $0 as? UIControl })
                .first(where: { $0.accessibilityLabel == "Search" && isVisible($0) })
              {
                control.performPrimaryAction()
                activated = true
              }
              let field = descendants(window).compactMap { $0 as? UITextField }.first {
                $0.isFirstResponder && $0.text == query
              }
              let visibleTags = NotebookSurfaceCaptureWorkspace.tags.filter {
                visibleElement("tag-choice-\($0.id)", in: window) != nil
              }.map(\.id)
              let expected = expectedTagID.map { [$0] } ?? []
              let emptyVisible = expectedTagID != nil || visibleElement("tag-empty", in: window) != nil
              complete = activated && field != nil && keyboardHeight >= 150
                && visibleTags == expected && emptyVisible
              evidence.focusedFieldText = field?.text
              evidence.matchedTagCount = visibleTags.count
            case .newTag, .editTag:
              let expectedTitle = step == .newTag ? "New Tag" : "Edit Tag"
              let bar = descendants(window).compactMap { $0 as? UINavigationBar }.first {
                $0.topItem?.title == expectedTitle && isVisible($0)
              }
              let field = descendants(window).compactMap { $0 as? UITextField }.first {
                $0.isFirstResponder
              }
              complete = bar != nil
                && (step != .newTag || (field != nil && keyboardHeight >= 150))
              evidence.formTitle = bar?.topItem?.title
              evidence.focusedFieldText = field?.text
            case .end, .signOut, .accentError, .accentSave:
              let scroll = scrollToEnd(in: window)
              evidence.scrollEndVisible = scroll?.atEnd == true
              evidence.scrollOffset = scroll?.offset
              evidence.scrollMaximum = scroll?.maximum
              switch step {
              case .end(let requiredID):
                if visibleElement(requiredID, in: window) != nil {
                  evidence.endElementID = requiredID
                }
                complete = scroll?.atEnd == true && evidence.endElementID != nil
              case .accentSave:
                evidence.pendingAccentVisible = visibleElement("settings-save-accent", in: window) != nil
                complete = scroll?.atEnd == true
                  && evidence.pendingAccentVisible
              case .accentError:
                evidence.errorVisible = visibleElement("settings-accent-error", in: window) != nil
                evidence.pendingAccentVisible = visibleElement("settings-save-accent", in: window) != nil
                complete = evidence.errorVisible && evidence.pendingAccentVisible && scroll?.atEnd == true
              case .signOut:
                let alert = topController(in: window) as? UIAlertController
                evidence.confirmationVisible =
                  alert?.preferredStyle == .alert
                  && alert?.title == "Sign Out?"
                  && alert?.message == "Drafts for @octavia stay on this iPhone. Nothing is published."
                  && alert?.actions.contains(where: { $0.title == "Sign Out" && $0.style == .destructive }) == true
                  && alert?.actions.contains(where: { $0.title == "Cancel" && $0.style == .cancel }) == true
                  && alert?.viewIfLoaded?.window != nil
                complete = evidence.confirmationVisible
              default:
                break
              }
            case .menu, .unsupported:
              throw NotebookSurfaceCaptureFailure(message: "Unexpected presentation capture step.")
            }
          }
          stableSamples = complete && evidence == previousEvidence ? stableSamples + 1 : 0
          previousEvidence = evidence
          if stableSamples >= 3 {
            ready(window, keyboardHeight, evidence)
            return
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        let controls = descendants(window).compactMap { view -> String? in
          guard view is UIControl, isVisible(view) else { return nil }
          return view.accessibilityLabel
        }
        let scrolls = descendants(window).compactMap { $0 as? UIScrollView }.map {
          "bounds=\($0.bounds) content=\($0.contentSize) offset=\($0.contentOffset)"
        }
        let ids = ["tag-create", "tag-choice-everyday", "tag-choice-ideas", "tag-empty",
          "settings-sign-out", "settings-save-accent", "settings-accent-error", "account-switch-export"].map {
          let element = notebookAccessibilityElement($0, in: window)
          return "\($0)=\(element.map { String(describing: $0.accessibilityFrame) } ?? "missing")"
        }
        throw NotebookSurfaceCaptureFailure(
          message: "The native \(step) capture did not reach a settled, visible state. "
            + "Evidence: \(previousEvidence?.metadata ?? [:]). Controls: \(controls). "
            + "Elements: \(ids). Scrolls: \(scrolls). Top: \(String(describing: topController(in: window))).")
      } catch is CancellationError {
        return
      } catch {
        failed(error.localizedDescription)
      }
    }
  }

  private func topController(in window: UIWindow) -> UIViewController? {
    var controller = window.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func scrollToEnd(in window: UIWindow) -> (atEnd: Bool, offset: CGFloat, maximum: CGFloat)? {
    guard let surface = window.rootViewController?.presentedViewController?.viewIfLoaded,
      let scroll = descendants(surface).compactMap({ $0 as? UIScrollView })
        .filter({ isVisible($0) && $0.bounds.height > 0 && $0.contentSize.height > 0 })
        .max(by: { $0.bounds.height < $1.bounds.height })
    else { return nil }
    let maximum = max(
      -scroll.adjustedContentInset.top,
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    if abs(scroll.contentOffset.y - maximum) > 0.5 {
      scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: maximum), animated: false)
      scroll.layoutIfNeeded()
    }
    return (abs(scroll.contentOffset.y - maximum) <= 0.5, scroll.contentOffset.y, maximum)
  }

  private func visibleElement(_ identifier: String, in window: UIWindow) -> NSObject? {
    guard let element = notebookAccessibilityElement("capture-frame-\(identifier)", in: window),
      let scene = window.windowScene
    else { return nil }
    let frame: CGRect
    if let view = element as? UIView {
      guard view.window != nil, isVisible(view) else { return nil }
      frame = window.convert(view.bounds, from: view)
    } else {
      frame = window.convert(element.accessibilityFrame, from: scene.effectiveGeometry.coordinateSpace)
    }
    let visible = window.bounds.inset(by: window.safeAreaInsets)
      .intersection(CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height - keyboardHeight))
    return frame.width > 0 && frame.height > 0 && visible.contains(frame) ? element : nil
  }

  private func openMenu(_ menu: NotebookMenuCapture, in window: UIWindow) {
    guard let scene = window.windowScene else {
      failed("The native note menu has no attached window scene.")
      return
    }
    readiness = Task { @MainActor in
      do {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var opened = false
        var activeSamples = 0
        var stableSamples = 0
        while ContinuousClock.now < deadline {
          try Task.checkCancellation()
          guard view.window === window, !window.isHidden else { return }
          window.layoutIfNeeded()
          if !opened {
            if UIApplication.shared.applicationState == .active, window.isKeyWindow,
              let control = menuControl(menu, in: window), isVisible(control)
            {
              activeSamples += 1
              if activeSamples >= 3 {
                control.performPrimaryAction()
                opened = true
              }
            } else {
              activeSamples = 0
            }
          }
          let titles = Set(scene.windows.filter { !$0.isHidden }.flatMap {
            descendants($0).filter(isVisible).compactMap { ($0 as? UILabel)?.text }
          })
          stableSamples = opened && titles.isSuperset(of: menu.expectedTitles) ? stableSamples + 1 : 0
          if stableSamples >= 4 {
            ready(window, 0, .init())
            return
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        failed("The native \(menu.rawValue) did not expose all expected menu commands.")
      } catch is CancellationError {
        return
      } catch {
        failed(error.localizedDescription)
      }
    }
  }

  private func menuControl(_ menu: NotebookMenuCapture, in window: UIWindow) -> UIControl? {
    if menu == .title {
      guard let bar = descendants(window).compactMap({ $0 as? UINavigationBar }).last else {
        return nil
      }
      return descendants(bar).compactMap { $0 as? UIControl }.first {
        $0.accessibilityLabel?.contains("A place for good ideas") == true
          || descendants($0).compactMap { $0 as? UILabel }.contains {
            $0.text == "A place for good ideas"
          }
      }
    }
    return descendants(window).compactMap { $0 as? UIControl }.first {
      $0.accessibilityIdentifier == "note-actions"
        || $0.accessibilityLabel == "Note actions"
        || $0.accessibilityLabel == "More"
        || ($0 as? UIButton)?.menu.map { menuTitles($0).contains("Intelligence…") } == true
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func isVisible(_ view: UIView) -> Bool {
    guard !view.isHidden, view.alpha > 0.99 else { return false }
    return view.superview.map(isVisible) ?? true
  }

  private func menuTitles(_ menu: UIMenu) -> [String] {
    menu.children.flatMap { item in
      if let menu = item as? UIMenu { return menuTitles(menu) }
      return [(item as? UIAction)?.title].compactMap { $0 }
    }
  }
}

private enum NotebookSurfaceCaptureStep: Equatable {
  case menu(String)
  case tagSearch(query: String, expectedTagID: String?)
  case newTag
  case editTag
  case end(requiredID: String)
  case signOut
  case accentError
  case accentSave
  case unsupported(String)

  var waitsForChildPresentation: Bool {
    switch self {
    case .tagSearch, .newTag, .editTag, .signOut: true
    default: false
    }
  }
}

private struct NotebookSurfaceCaptureEvidence: Equatable {
  var matchedTagCount: Int?
  var focusedFieldText: String?
  var formTitle: String?
  var endElementID: String?
  var scrollEndVisible = false
  var scrollOffset: CGFloat?
  var scrollMaximum: CGFloat?
  var errorVisible = false
  var pendingAccentVisible = false
  var confirmationVisible = false

  var metadata: [String: Any] {
    var values: [String: Any] = [:]
    if let matchedTagCount { values["matchedTagCount"] = matchedTagCount }
    if let focusedFieldText { values["focusedFieldText"] = focusedFieldText }
    if let formTitle { values["formTitle"] = formTitle }
    if let endElementID { values["endElementID"] = endElementID }
    if let scrollOffset, let scrollMaximum {
      values["scrollOffset"] = scrollOffset
      values["scrollMaximum"] = scrollMaximum
      values["scrollEndVisible"] = scrollEndVisible
    }
    if errorVisible { values["errorVisible"] = true }
    if pendingAccentVisible { values["pendingAccentVisible"] = true }
    if confirmationVisible { values["confirmationVisible"] = true }
    return values
  }
}

private struct NotebookSurfaceCaptureFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private enum NotebookMenuCapture: String {
  case title = "title-menu"
  case more = "more-menu"

  var expectedTitles: Set<String> {
    switch self {
    case .title: ["README.md", "Ideas.md", "Rename File…", "Add File…"]
    case .more: ["Rename Note…", "Intelligence…", "Archive", "Delete Note…"]
    }
  }
}
#endif
