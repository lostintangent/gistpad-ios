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
    let link: GistPadLink?
    let mode: FileMode?
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
      link = value("--open").map {
        GistPadLink(url: URL(string: $0 == "today" ? "gistpad://today" : "gistpad://note/\($0)")!)!
      }
      mode = value("--mode").map { ["edit": FileMode.edit, "preview": .preview, "split": .split][$0]! }
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

    /// The sheet still to present. The root view clears it once it's up. Today arrives as a link.
    @MainActor static var pendingSheet = current?.sheet == .today ? nil : current?.sheet

    @MainActor
    func library() async throws -> Library {
      let server = FixtureServer()
      if fixture == .standard || fixture == .offline { try FixtureLibrary.seed(server) }
      let accounts = try server.accounts()
      if fixture != .signedOut {
        let account = try await server.signIn(accounts)
        let seeded = fixture == .empty ? [] : FixtureLibrary.preferences
        _ = try await accounts.update(seeded + (accent.map { [.setAccentColor($0)] } ?? []), accountID: account.id)
      }
      let store = try DraftStore.open(inMemory: true)
      let sync = GitHubSync(accounts: accounts, drafts: store)
      if fixture == .offline, let account = try await sync.connectedAccount() {
        try await sync.cacheLibrary(
          owned: sync.gists(accountID: account.id), starred: sync.starredGists(accountID: account.id),
          account: account)
        server.intercept { _ in throw URLError(.notConnectedToInternet) }
      }
      if let link = sheet == .today ? .addToToday : link { PendingLink.shared.link = link }
      let library = PlatformBridge.connect(
        sync, store: store, lastOpened: LastOpened(defaults: Self.defaults))
      if let query { library.state.query = query }
      return library
    }

    @MainActor
    func layout() -> LayoutPreferences {
      let layout = LayoutPreferences(defaults: Self.defaults)
      if let mode { layout.select(mode) }
      return layout
    }
  }
#endif
