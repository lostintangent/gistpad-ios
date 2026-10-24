import GistPadEditor
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
      if LaunchArguments.captureScreen == "photos" {
        PhotoCaptureWorkspace()
      } else if LaunchArguments.captureScreen == "scroll-edges" {
        ScrollEdgeCaptureWorkspace()
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
        let environment = ProcessInfo.processInfo.environment
        let isTesting =
          environment["GISTPAD_TESTING"] == "1" || environment["GISTPAD_FOLD_PROBE"] == "1"
        let longFixture =
          ProcessInfo.processInfo.arguments.contains("--long-fixture")
          || LaunchArguments.captureScreen == "editor"
        if LaunchArguments.captureScreen != nil || longFixture || isTesting {
          let text: String
          if let screen = LaunchArguments.captureScreen, ["library", "note"].contains(screen) {
            text = try LaunchArguments.captureReadingFixture
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
            Button("Retry", action: load)
              .buttonStyle(.borderedProminent)
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
    }
  }
}

enum LaunchArguments {
  static let captureReadingFixture =
    ProcessInfo.processInfo.arguments.contains("--capture-reading-fixture")

  static let captureScreen: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--capture-screen"), index + 1 < arguments.count
    else {
      return captureReadingFixture ? "note" : nil
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
