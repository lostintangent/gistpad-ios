import GistPadPlatform
import SwiftUI

@main
struct GistPadApp: App {
  @State private var notebook: NotebookModel?
  @State private var loadError: String?
  @State private var routeError: String?

  init() {
    NotebookPlatformBootstrap.install()
  }

  /// Host tests run inside the app, so it stays out of their way.
  private static let isHostingTests = ["GISTPAD_TESTING", "GISTPAD_FOLD_PROBE"].contains {
    ProcessInfo.processInfo.environment[$0] == "1"
  }

  private func load() async {
    loadError = nil
    do {
      #if DEBUG
        if let fixture = FixtureLaunch.current {
          notebook = try await fixture.notebook()
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

  @ViewBuilder
  private func workspace(_ notebook: NotebookModel) -> some View {
    #if DEBUG
      if let fixture = FixtureLaunch.current {
        LiveNotebookWorkspace(notebook: notebook, layout: fixture.layout())
      } else {
        LiveNotebookWorkspace(notebook: notebook)
      }
    #else
      LiveNotebookWorkspace(notebook: notebook)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let notebook {
          workspace(notebook)
        } else if let loadError {
          ContentUnavailableView {
            Label("Couldn't Load Your Gists", systemImage: "exclamationmark.triangle")
          } description: {
            Text(loadError)
          } actions: {
            Button("Retry") { Task { await load() } }
              .buttonStyle(.borderedProminent)
          }
        } else if !Self.isHostingTests {
          ProgressView()
        }
      }
      .task {
        guard notebook == nil, !Self.isHostingTests else { return }
        await load()
      }
      .onOpenURL { url in
        if url.scheme == "gistpad", url.host == "auth-callback" { return }
        if let route = NotebookRoute(url: url) {
          NotebookRouteInbox.shared.submit(route)
        } else {
          routeError = String(localized: "GistPad can't open this link.")
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
        NotebookSceneAccent(savedHex: notebook?.account?.preferences.accentColor)
          .frame(width: 0, height: 0)
      }
    }
  }
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
