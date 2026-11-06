import AppIntents
import Editor
import Foundation
import Notebook
import OSLog
import Platform
import Sync
import UIKit
import WidgetKit

@MainActor
extension PlatformBridge {
  private static var services: (library: Library, bridge: PlatformBridge)?
  static var shared: PlatformBridge? { services?.bridge }

  static func install() {
    AppDependencyManager.shared.add { () async throws -> any DailyNoteActions in
      try await MainActor.run {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
          !key.isEmpty, !key.contains("$(")
        else { throw AccountError.invalidConfiguration }
        _ = try library(publishableKey: key)
        return services!.bridge
      }
    }
  }

  static func library(publishableKey: String) throws -> Library {
    if let services { return services.library }
    let store = try DraftStore.open()
    let sync = GitHubSync(
      accounts: try AccountStore(publishableKey: publishableKey), drafts: store)
    return connect(sync, store: store, lastOpened: LastOpened(defaults: .standard))
  }

  /// Builds the library and connects it to App Intents, widgets and Spotlight.
  static func connect(
    _ sync: GitHubSync, store: DraftStore, lastOpened: LastOpened
  ) -> Library {
    let library = Library(sync: sync, lastOpened: lastOpened)
    services = (library, PlatformBridge(sync: sync, store: store, library: library))
    return library
  }
}

@MainActor
final class PlatformBridge: DailyNoteActions {
  private struct WeakSession {
    weak var value: FileSession?
  }

  private let sync: GitHubSync
  private let store: DraftStore
  private weak var library: Library?
  private var visibleSession: WeakSession?
  private var visibleNoteID: String?
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  /// Starts from the snapshot GistPad launched with, read before the first refresh rewrites it.
  private let spotlight = GistSpotlightIndex(launchedWith: try? LibrarySnapshot.read())
  private var spotlightSnapshot: LibrarySnapshot?
  private var spotlightTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SystemIntegration")

  init(sync: GitHubSync, store: DraftStore, library: Library) {
    self.sync = sync
    self.store = store
    self.library = library
    followLibrary()
    // Launch also catches up on anything that changed while the app wasn't running.
    scheduleRefresh()
  }

  /// Widgets, Spotlight and Shortcuts follow the library's account and the drafts on this iPhone.
  private func followLibrary() {
    withObservationTracking {
      _ = (library?.account, library?.pendingAccount, library?.localDrafts)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleRefresh()
        self?.followLibrary()
      }
    }
  }

  func setVisibleNote(_ id: String?, session: FileSession) {
    if let id {
      visibleSession = WeakSession(value: session)
      visibleNoteID = id
    } else if visibleSession?.value === session {
      visibleSession = nil
      visibleNoteID = nil
    }
  }

  func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
        try await self?.refresh()
      } catch is CancellationError {
        return
      } catch {
        self?.logger.error(
          "Widget and Spotlight refresh failed: \(String(reflecting: type(of: error)), privacy: .public)")
      }
    }
  }

  func refresh() async throws {
    let account = try await sync.cachedAccount()
    let accountID =
      library?.pendingAccount == nil
        && (library?.account == nil || library?.account?.id == account?.id)
      ? account?.id : nil
    let local: LocalState?
    if let accountID {
      local = try await sync.localState(accountID: accountID)
    } else {
      local = nil
    }
    let snapshot = LibrarySnapshot.make(
      accountID: accountID, cache: local?.cache, drafts: local?.drafts ?? [],
      visibleText: Self.noteBody)
    try Task.checkCancellation()
    let current = try await sync.cachedAccount()
    guard current?.id == account?.id else { throw PlatformError.accountChanged }
    try snapshot.write()
    WidgetCenter.shared.reloadTimelines(ofKind: LauncherWidgetView.kind)
    indexInSpotlight(snapshot)
  }

  nonisolated private static func noteBody(_ source: String) -> String {
    (source as NSString).substring(from: Syntax.contentStart(in: source))
  }

  func noteEntities(for identifiers: [String]) async throws -> [GistEntity] {
    guard let accountID = try await sync.cachedAccount()?.id else {
      throw PlatformError.accountChanged
    }
    try await validateAccount(accountID)
    let local = try await sync.localState(accountID: accountID)
    let snapshot = LibrarySnapshot.make(
      accountID: accountID, cache: local.cache, drafts: local.drafts,
      visibleText: Self.noteBody)
    return snapshot.gists.filter { identifiers.contains($0.id) }.map { entity in
      guard let body = visibleBody(for: entity, accountID: accountID) else { return entity }
      return entity.withBody(body)
    }
  }

  private func visibleBody(for note: GistEntity, accountID: UUID) -> String? {
    guard note.id == visibleNoteID, let session = visibleSession?.value,
      library?.isForeground == true, library?.activeSession === session,
      library?.state.selectedID != nil,
      session.draft.accountID == accountID
    else { return nil }
    return Self.noteBody(session.editor.text)
  }

  /// Spotlight catches up with the newest snapshot in the background, so nothing waits on it.
  private func indexInSpotlight(_ snapshot: LibrarySnapshot) {
    spotlightSnapshot = snapshot
    guard spotlightTask == nil else { return }
    spotlightTask = Task {
      while let snapshot = spotlightSnapshot {
        spotlightSnapshot = nil
        do {
          try await spotlight.update(snapshot)
        } catch {
          logger.error(
            "Spotlight update failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
      }
      spotlightTask = nil
    }
  }

  @discardableResult
  func addToToday(
    text: String, asTask: Bool, target: DailyNote.Day
  ) async throws -> GistPadLink {
    try await serially {
      guard let accountID = try await self.sync.cachedAccount()?.id else {
        throw PlatformError.accountChanged
      }
      let draft = try await self.todayDraft(accountID: accountID, target: target)
      try await self.apply(.addToToday(text, asTask: asTask, to: draft))
      return draft.gistID.map { .gist(id: $0, filename: draft.filename) }
        ?? .unpublishedGist(accountID: accountID, draftID: draft.id)
    }
  }

  func createNote(name: String, content: String?) async throws -> GistEntity {
    try await serially {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw PlatformError.emptyNoteName }
      guard let accountID = try await self.sync.cachedAccount()?.id,
        let library = self.library
      else { throw PlatformError.accountChanged }
      try await self.validateAccount(accountID)
      let draft = try await self.sync.createDraft(
        accountID: accountID, description: name, content: content)
      try await library.reloadPlatformState(accountID: accountID)
      do {
        try await self.refresh()
      } catch {
        self.logger.error(
          "Created note needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
        self.scheduleRefresh()
      }
      let link = GistPadLink.unpublishedGist(accountID: accountID, draftID: draft.id)
      guard let entity = try await self.noteEntities(for: [link.url.absoluteString]).first else {
        throw DraftError.notFound
      }
      PendingLink.shared.link = link
      return entity
    }
  }

  func appendToNote(_ note: GistEntity, text: String) async throws -> GistEntity {
    try await serially {
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PlatformError.emptyNoteText
      }
      let draft = try await self.noteDraft(for: note)
      let newline = draft.text.contains("\r\n") ? "\r\n" : "\n"
      let addition = (draft.text.isEmpty || draft.text.last?.isNewline == true ? "" : newline)
        + text + (text.last?.isNewline == true ? "" : newline)
      try await self.apply(DraftEdit(draft: draft, text: addition))
      guard let body = self.visibleBody(for: note, accountID: draft.accountID) else {
        return note.withoutBody()
      }
      return note.withBody(body)
    }
  }

  func updateNote(
    _ note: GistEntity, name: String?, isPinned: Bool?
  ) async throws -> GistEntity {
    try await serially {
      let draft = try await self.noteDraft(for: note)
      guard let library = self.library else { throw PlatformError.accountChanged }
      let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
      let renames = name != nil && name != String(note.name.characters)
      let changesPin = isPinned != nil && isPinned != note.isPinned
      guard !(renames && changesPin) else { throw PlatformError.unsupportedNoteUpdate }
      if renames {
        guard let name else { throw PlatformError.unsupportedNoteUpdate }
        guard !name.isEmpty else { throw PlatformError.unsupportedNoteUpdate }
        switch note.link {
        case .gist(let id, nil):
          guard draft.description != DailyNote.gistDescription else {
            throw PlatformError.unsupportedNoteUpdate
          }
          try await library.rename(gistID: id, to: name)
        case .unpublishedGist:
          try await library.rename(draft, to: name)
        case .gist, .today, .addToToday, .newGist:
          throw PlatformError.unsupportedNoteUpdate
        }
      }
      if changesPin {
        guard let isPinned else { throw PlatformError.unsupportedNoteUpdate }
        guard case .gist(let id, _) = note.link else {
          throw PlatformError.unsupportedNoteUpdate
        }
        try await library.updatePreferences([.setPinned(gistID: id, pinned: isPinned)])
      }
      do {
        try await self.refresh()
      } catch {
        self.logger.error(
          "Updated note needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
        self.scheduleRefresh()
      }
      return note.withMetadata(
        name: renames ? name : nil, isPinned: changesPin ? isPinned : nil)
    }
  }

  private func noteDraft(for note: GistEntity) async throws -> Draft {
    guard let accountID = try await sync.cachedAccount()?.id, note.accountID == accountID else {
      throw PlatformError.accountChanged
    }
    try await validateAccount(accountID)
    switch note.link {
    case .gist(let id, let filename):
      let local = try await sync.localState(accountID: accountID)
      guard let gist = local.cache?.owned.first(where: { $0.id == id }),
        let filename = filename ?? gist.defaultMarkdownFilename,
        filename.hasSuffix(".md")
      else { throw DraftError.readOnly }
      if let existing = local.drafts.first(where: {
        $0.gistID == id && $0.filename == filename
      }) {
        return try await current(existing)
      }
      guard gist.markdownFilenames.contains(filename) else { throw DraftError.notFound }
      let userID = try await sync.verifiedUserID(accountID: accountID)
      let text = try await sync.content(gist: gist, filename: filename, accountID: accountID)
      return try await current(
        Draft(accountID: accountID, githubUserID: userID, gist: gist, filename: filename, text: text))
    case .unpublishedGist(let owner, let id):
      guard owner == accountID else { throw PlatformError.accountChanged }
      guard let draft = try await store.draft(id: id, accountID: accountID) else {
        throw DraftError.notFound
      }
      guard draft.gistID == nil else { throw DraftError.staleGeneration }
      return try await current(draft)
    case .today, .addToToday, .newGist:
      throw DraftError.notFound
    }
  }

  /// Today's file as you last saved it, started the same way the app starts today.
  private func todayDraft(
    accountID: UUID, target: DailyNote.Day = DailyNote.Day()
  ) async throws -> Draft {
    try await validateAccount(accountID)
    return try await current(try await sync.today(accountID: accountID, target: target).draft)
  }

  /// The note as you last saved it, from its open editor once your typing there is saved.
  private func current(_ draft: Draft) async throws -> Draft {
    guard let session = session(for: draft) else { return try await store.current(draft) }
    guard session.canMutate, await session.waitForLocalSave() else {
      throw PlatformError.editingInProgress
    }
    return session.draft
  }

  private func session(for draft: Draft) -> FileSession? {
    library?.sessions.values.first { (session: FileSession) in
      session.draft.id == draft.id
        || (session.draft.gistID != nil && session.draft.gistID == draft.gistID
          && session.draft.filename == draft.filename)
    }
  }

  func validateAccount(_ accountID: UUID) async throws {
    guard let current = try await sync.cachedAccount(), current.id == accountID,
      library?.pendingAccount == nil,
      library?.account == nil || library?.account?.id == accountID
    else { throw PlatformError.accountChanged }
  }

  private func apply(_ edit: DraftEdit) async throws {
    let accountID = edit.draft.accountID
    if case .conflict = edit.draft.state { throw PlatformError.editingInProgress }
    let session = session(for: edit.draft)
    if let session {
      guard !session.file.isRecovery, session.canMutate else {
        throw PlatformError.editingInProgress
      }
      try await session.applyDurableEdit(edit) {
        try await self.validateAccount(accountID)
        return try await self.store.apply(edit)
      }
    } else {
      _ = try await store.apply(edit)
    }
    do {
      if library?.account?.id == accountID {
        try await library?.reloadPlatformState(accountID: accountID)
      }
      try await refresh()
    } catch {
      logger.error(
        "Accepted system edit needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
      scheduleRefresh()
    }
    if UIApplication.shared.applicationState != .active {
      let lease = BackgroundLease()
      defer { lease.end() }
      guard lease.isActive else {
        logger.info("System edit is durable. No background publication lease is available.")
        return
      }
      do {
        if let session {
          await session.publish(reason: .background, shouldContinue: { lease.isActive })
        } else {
          _ = try await library?.publish(edit.draft)
        }
        try await refresh()
      } catch {
        logger.error(
          "System edit remains local after background save failed: \(String(reflecting: type(of: error)), privacy: .public)")
        scheduleRefresh()
      }
    }
  }

  private func serially<Value: Sendable>(
    _ action: @escaping @MainActor () async throws -> Value
  ) async throws -> Value {
    let previous = operation
    let task = Task {
      await previous?.value
      return try await action()
    }
    operation = Task { _ = try? await task.value }
    return try await task.value
  }
}
