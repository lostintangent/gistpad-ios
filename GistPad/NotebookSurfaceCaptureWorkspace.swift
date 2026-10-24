#if DEBUG
import GistPadEditor
import GistPadInterface
import GistPadSync
import SwiftUI
import UIKit

struct NotebookSurfaceCaptureWorkspace: View {
  let screen: String
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

  init(screen: String) {
    self.screen = screen
    _path = State(initialValue: [screen])
    let arguments = ProcessInfo.processInfo.arguments
    let accent: String
    if let index = arguments.firstIndex(of: "--capture-accent"),
      arguments.indices.contains(index + 1)
    {
      accent = arguments[index + 1]
    } else {
      accent = "#0EA5E9"
    }
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
        case .account:
          NotebookAccountSwitchSheet(
            current: "octavia", replacement: "mira", export: { Data("[]".utf8) },
            switchAccount: { presentedSheet = nil }, keepCurrent: { presentedSheet = nil })
        case .captureToday:
          AddToTodaySheet()
        }
      }
      .background { readinessMarker }
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
      guard screen == "capture-today",
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
      requiresKeyboard: screen == "capture-today", keyboardHeight: keyboardHeight,
      failed: { readinessError = $0 }
    ) { window, keyboardHeight in
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--capture-ready-token"),
        arguments.indices.contains(index + 1),
        UUID(uuidString: arguments[index + 1]) != nil
      else { return }
      let token = arguments[index + 1]
      do {
        let data = try JSONSerialization.data(withJSONObject: [
          "screen": screen, "fixture": "native-surfaces", "token": token,
          "accent": preferences.accentColor ?? "",
          "contentSizeCategory": window.traitCollection.preferredContentSizeCategory.rawValue,
          "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
          "keyboardHeight": keyboardHeight,
        ], options: [.sortedKeys])
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
      PersonalAccentColorRow(savedHex: preferences.accentColor) {
        preferences = try preferences.applying(.setAccentColor($0))
      }
    }
  }

  private enum CaptureSheet: String, Identifiable {
    case settings, tags, account
    case captureToday = "capture-today"
    var id: Self { self }
  }

  private static let tags = [
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
  let failed: @MainActor (String) -> Void
  let ready: @MainActor (UIWindow, CGFloat) -> Void

  func makeUIViewController(context: Context) -> NotebookSurfaceReadinessController {
    NotebookSurfaceReadinessController(
      requiresKeyboard: requiresKeyboard, failed: failed, ready: ready)
  }

  func updateUIViewController(_ controller: NotebookSurfaceReadinessController, context: Context) {
    controller.keyboardHeight = keyboardHeight
  }
}

private final class NotebookSurfaceReadinessController: UIViewController {
  private let requiresKeyboard: Bool
  private let failed: @MainActor (String) -> Void
  private let ready: @MainActor (UIWindow, CGFloat) -> Void
  private var readiness: Task<Void, Never>?
  var keyboardHeight: CGFloat = 0

  init(
    requiresKeyboard: Bool, failed: @escaping @MainActor (String) -> Void,
    ready: @escaping @MainActor (UIWindow, CGFloat) -> Void
  ) {
    self.requiresKeyboard = requiresKeyboard
    self.failed = failed
    self.ready = ready
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard let window = view.window else { return }
    window.layoutIfNeeded()
    guard requiresKeyboard else { ready(window, 0); return }
    readiness = Task { @MainActor in
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      var previousHeight: CGFloat = 0
      var stableSamples = 0
      do {
        while ContinuousClock.now < deadline {
          try Task.checkCancellation()
          guard view.window === window, !window.isHidden else { return }
          window.layoutIfNeeded()
          let height = keyboardHeight
          if height >= 150, hasFocusedTextEditor(window) {
            stableSamples = abs(height - previousHeight) < 0.5 ? stableSamples + 1 : 0
            if stableSamples >= 3 { ready(window, height); return }
          } else {
            stableSamples = 0
          }
          previousHeight = height
          try await Task.sleep(for: .milliseconds(16))
        }
        failed(
          "The native Today editor did not acquire a visible, settled keyboard. "
            + "Focused: \(hasFocusedTextEditor(window)), keyboard height: \(keyboardHeight).")
      } catch is CancellationError {
        return
      } catch {
        failed(error.localizedDescription)
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    readiness?.cancel()
    readiness = nil
    super.viewWillDisappear(animated)
  }

  private func hasFocusedTextEditor(_ view: UIView) -> Bool {
    (view is UITextView && view.isFirstResponder) || view.subviews.contains(where: hasFocusedTextEditor)
  }
}
#endif
