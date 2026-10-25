import GistPadEditor
import GistPadInterface
import GistPadPreview
import GistPadPlatform
import SwiftUI

@main
struct GistPadApp: App {
  @State private var notebook: NotebookModel?
  @State private var fixtureSession: DocumentSession?
  @State private var loadError: String?
  @State private var routeError: String?

  init() {
    NotebookPlatformBootstrap.install()
  }

  @ViewBuilder
  private func fixtureWorkspace(session: DocumentSession) -> some View {
    #if DEBUG
      if LaunchArguments.evaluatesIntelligence {
        NotebookIntelligenceEvaluationWorkspace()
      } else if LaunchArguments.captureScreen == "library-delete" {
        NotebookLibraryDeletionCaptureWorkspace()
      } else if LaunchArguments.captureScreen == "photos" {
        PhotoCaptureWorkspace()
      } else if LaunchArguments.captureScreen == "intelligence" {
        NotebookIntelligenceCaptureWorkspace()
      } else if LaunchArguments.captureScreen == "scroll-edges" {
        ScrollEdgeCaptureWorkspace()
      } else if LaunchArguments.captureScreen == "comment-highlights" {
        CommentHighlightCaptureWorkspace(session: session)
      } else if let screen = LaunchArguments.captureScreen, ["library", "note"].contains(screen) {
        InterfaceCaptureWorkspace(session: session)
      } else if let screen = LaunchArguments.captureScreen,
        NotebookSurfaceCaptureWorkspace.supports(screen)
      {
        NotebookSurfaceCaptureWorkspace(screen: screen)
      } else {
        NotebookWorkspace(session: session)
      }
    #else
      NotebookWorkspace(session: session)
    #endif
  }

  private func load() {
    loadError = nil
    do {
      #if DEBUG
        if LaunchArguments.evaluatesIntelligence {
          fixtureSession = DocumentSession(documentID: "intelligence-evaluation", text: "")
          return
        }
        let environment = ProcessInfo.processInfo.environment
        let isTesting =
          environment["GISTPAD_TESTING"] == "1" || environment["GISTPAD_FOLD_PROBE"] == "1"
        let longFixture =
          ProcessInfo.processInfo.arguments.contains("--long-fixture")
          || LaunchArguments.captureScreen == "editor"
        if LaunchArguments.captureScreen != nil || longFixture || isTesting {
          let text: String
          if LaunchArguments.captureScreen == "comment-highlights" {
            text = CommentHighlightCaptureWorkspace.markdown
          } else if LaunchArguments.captureMarkerFixture {
            text = try PreviewFixtures.listMarkers
          } else if let screen = LaunchArguments.captureScreen, ["library", "note"].contains(screen) {
            text = try LaunchArguments.captureMangaFixture ? PreviewFixtures.mangaReading
              : LaunchArguments.captureReadingFixture
              ? PreviewFixtures.readingPolish : InterfaceCaptureWorkspace.markdown
          } else {
            text = try longFixture ? EditorFixture.markdown() : PreviewFixtures.allSyntax
          }
          fixtureSession = DocumentSession(documentID: "phase-zero-editor", text: text)
          return
        }
      #endif
      guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
        !key.isEmpty, !key.contains("$(")
      else {
        throw NotebookConfigurationError.missingPublicKey
      }
      notebook = try NotebookPlatformBootstrap.notebook(publishableKey: key)
    } catch {
      loadError = error.localizedDescription
    }
  }

  private var sceneAccent: String? {
    if let notebook { return notebook.account?.preferences.accentColor }
    #if DEBUG
      return LaunchArguments.captureAccent
    #else
      return nil
    #endif
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let notebook {
          LiveNotebookWorkspace(notebook: notebook)
        } else if let fixtureSession {
          fixtureWorkspace(session: fixtureSession)
        } else if let loadError {
          ContentUnavailableView {
            Label("Notebook unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(loadError)
          } actions: {
            Button(action: load) {
              Text("Retry")
                .foregroundStyle(Color(uiColor: .systemBackground))
            }
              .buttonStyle(.borderedProminent)
              .tint(Color(uiColor: .label))
          }
        } else {
          ProgressView("Opening notebook")
        }
      }
      .task {
        guard notebook == nil, fixtureSession == nil else { return }
        load()
      }
      .onOpenURL { url in
        if url.scheme == "gistpad", url.host == "auth-callback" { return }
        do { try NotebookRouteInbox.shared.receive(url) }
        catch {
          routeError = String(localized: "This link doesn't point to a supported GistPad note.")
        }
      }
      .alert("Cannot Open Link", isPresented: Binding(
        get: { routeError != nil },
        set: { if !$0 { routeError = nil } })
      ) {
        Button("OK") { routeError = nil }
      } message: {
        Text(routeError ?? "")
      }
      .background {
        NotebookSceneAccent(savedHex: sceneAccent)
          .frame(width: 0, height: 0)
      }
      .gitHubStatusKeyboardPolicy()
      #if DEBUG
        .preferredColorScheme(LaunchArguments.captureColorScheme)
        .background {
          if LaunchArguments.captureMarkerFixture {
            MarkerCaptureContrast(
              increased: ProcessInfo.processInfo.arguments.contains("--capture-increased-contrast")
            )
            .frame(width: 0, height: 0)
          }
        }
      #endif
    }
  }
}

enum LaunchArguments {
  #if DEBUG
    static let evaluatesIntelligence =
      ProcessInfo.processInfo.arguments.contains("--evaluate-intelligence")

    static let captureColorScheme: ColorScheme? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard captureScreen != nil,
        let index = arguments.firstIndex(of: "--capture-appearance"),
        arguments.indices.contains(index + 1)
      else { return nil }
      switch arguments[index + 1] {
      case "light": return .light
      case "dark": return .dark
      default: preconditionFailure("Unknown capture appearance.")
      }
    }()
  #endif
  static let captureAccent: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--capture-accent"),
      arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }()

  static let captureReadingFixture =
    ProcessInfo.processInfo.arguments.contains("--capture-reading-fixture")

  static let captureMangaFixture =
    ProcessInfo.processInfo.arguments.contains("--capture-manga-fixture")

  static let captureMarkerFixture =
    ProcessInfo.processInfo.arguments.contains("--capture-marker-fixture")

  static let captureScreen: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--capture-screen"), index + 1 < arguments.count
    else {
      return captureReadingFixture || captureMangaFixture ? "note" : nil
    }
    return arguments[index + 1]
  }()
}

private enum NotebookConfigurationError: LocalizedError {
  case missingPublicKey

  var errorDescription: String? {
    String(
      localized:
        "The public sign-in configuration is missing. Regenerate Public.xcconfig and rebuild the app."
    )
  }
}
