import GistPadPlatform
import GistPadSync
import SwiftUI

@main
struct GistPadApp: App {
  @State private var notebook: NotebookModel?
  @State private var loadError: String?
  @State private var cannotOpenLink = false

  init() {
    PlatformBridge.install()
  }

  /// Host tests run inside the app, so it stays out of their way.
  private static let isHostingTests =
    ProcessInfo.processInfo.environment["GISTPAD_TESTING"] == "1"

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
        throw AccountError.invalidConfiguration
      }
      notebook = try PlatformBridge.notebook(publishableKey: key)
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
            Label("Couldn't Load Your Gists", systemImage: "exclamationmark.circle")
          } description: {
            Text(loadError)
          } actions: {
            Button("Try Again") { Task { await load() } }
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
        if let link = GistPadLink(url: url) {
          PendingLink.shared.link = link
        } else {
          cannotOpenLink = true
        }
      }
      .alert("Cannot Open Link", isPresented: $cannotOpenLink) {
      } message: {
        Text("GistPad can't open this link.")
      }
      .accent(savedHex: notebook?.account?.preferences.accentColor)
    }
  }
}
