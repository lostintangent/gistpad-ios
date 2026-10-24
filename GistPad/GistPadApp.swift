import GistPadEditor
import GistPadPreview
import SwiftUI

@main
struct GistPadApp: App {
  @State private var notebook: NotebookModel?
  @State private var fixtureSession: DocumentSession?
  @State private var loadError: String?

  @ViewBuilder
  private func fixtureWorkspace(session: DocumentSession) -> some View {
    #if DEBUG
      if let screen = LaunchArguments.captureScreen, ["library", "note"].contains(screen) {
        InterfaceCaptureWorkspace(session: session)
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
            text = InterfaceCaptureWorkspace.markdown
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
      notebook = try NotebookModel(publishableKey: key)
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
    }
  }
}

enum LaunchArguments {
  static let captureScreen: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--capture-screen"), index + 1 < arguments.count
    else {
      return nil
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
