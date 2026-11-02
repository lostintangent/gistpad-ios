#if DEBUG
  import Foundation
  import GistPadInterface
  import GistPadPlatform
  import GistPadSync

  /// The one launch contract for UI tests and captures. `--fixture standard|empty|signed-out|offline` runs the
  /// real app against the fixture GitHub. `--open <gist>[/<file>]` (or `today`), `--mode edit|preview|split`,
  /// `--query <text>`, `--sheet tags|settings|today|intelligence|comments` and `--accent <#RRGGBB>` start it
  /// where a test or capture needs it.
  struct FixtureLaunch {
    enum Fixture: String { case standard, empty, signedOut = "signed-out", offline }
    enum Sheet: String { case tags, settings, today, intelligence, comments }

    let fixture: Fixture
    let route: NotebookRoute?
    let mode: NoteMode?
    let query: String?
    let sheet: Sheet?
    let accent: String?

    static let current = FixtureLaunch(arguments: ProcessInfo.processInfo.arguments)

    init?(arguments: [String]) {
      func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
      }
      guard let fixture = value("--fixture") else { return nil }
      self.fixture = Fixture(rawValue: fixture)!
      route = value("--open").map {
        NotebookRoute(url: URL(string: $0 == "today" ? "gistpad://today" : "gistpad://note/\($0)")!)!
      }
      mode = value("--mode").map { ["edit": NoteMode.source, "preview": .reading, "split": .split][$0]! }
      query = value("--query")
      sheet = value("--sheet").map { Sheet(rawValue: $0)! }
      accent = value("--accent")
    }

    /// Settings that would otherwise carry over from the last launch.
    @MainActor static let defaults: UserDefaults = {
      let defaults = UserDefaults(suiteName: "dev.gistpad.fixture")!
      defaults.removePersistentDomain(forName: "dev.gistpad.fixture")
      return defaults
    }()

    /// The sheet still to present. The workspace clears it once it's up. Today arrives as a route.
    @MainActor static var pendingSheet = current?.sheet == .today ? nil : current?.sheet

    @MainActor
    func notebook() async throws -> NotebookModel {
      let server = FixtureServer()
      if fixture == .standard || fixture == .offline { try FixtureLibrary.seed(server) }
      let accounts = try server.accounts()
      if fixture != .signedOut {
        let account = try await server.signIn(accounts)
        let seeded = fixture == .empty ? [] : FixtureLibrary.preferences
        _ = try await accounts.update(seeded + (accent.map { [.setAccentColor($0)] } ?? []), accountID: account.id)
      }
      let store = try DraftStore.open(inMemory: true)
      let provider = LiveNotebookProvider(accounts: accounts, drafts: store)
      if fixture == .offline, let account = try await provider.connectedAccount() {
        try await provider.cacheLibrary(
          owned: provider.gists(accountID: account.id), starred: provider.starredGists(accountID: account.id),
          account: account)
        server.intercept { _ in throw URLError(.notConnectedToInternet) }
      }
      if let route = sheet == .today ? .addToToday : route { NotebookRouteInbox.shared.submit(route) }
      let notebook = NotebookPlatformBootstrap.connect(
        provider, store: store, selections: NotebookSelectionStore(defaults: Self.defaults))
      if let query { notebook.library.query = query }
      return notebook
    }

    @MainActor
    func layout() -> NotebookLayoutPreferences {
      let layout = NotebookLayoutPreferences(defaults: Self.defaults)
      if let mode { layout.select(mode) }
      return layout
    }
  }
#endif
