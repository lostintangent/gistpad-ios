import Model
import Platform
import SwiftUI
import Store

@main
struct GistPadApp: App {
  @State private var model: GistPadModel?
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
          model = try await fixture.model()
          return
        }
      #endif
      guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
        !key.isEmpty, !key.contains("$(")
      else {
        throw AccountError.invalidConfiguration
      }
      model = try PlatformBridge.model(publishableKey: key)
    } catch {
      loadError = error.localizedDescription
    }
  }

  @ViewBuilder
  private func rootView(_ model: GistPadModel) -> some View {
    #if DEBUG
      if let fixture = FixtureLaunch.current {
        RootView(model: model, layout: fixture.layout())
      } else {
        RootView(model: model)
      }
    #else
      RootView(model: model)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let model {
          rootView(model)
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
        guard model == nil, !Self.isHostingTests else { return }
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
      .accent(savedHex: model?.account?.preferences.accentColor)
    }
  }
}
