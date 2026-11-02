import AppIntents
import Foundation
import GistPadPlatform
import GistPadSync
import OSLog
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

  static func register(_ session: FileSession, library: Library) {
    guard services?.library === library else { return }
    services?.bridge.register(session)
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
  private var sessions: [UUID: WeakSession] = [:]
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SystemIntegration")

  init(sync: GitHubSync, store: DraftStore, library: Library) {
    self.sync = sync
    self.store = store
    self.library = library
    followLibrary()
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

  func register(_ session: FileSession) {
    sessions = sessions.filter { $0.value.value != nil }
    sessions[session.draft.id] = WeakSession(value: session)
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

  func refresh(date: Date = .now) async throws {
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
      accountID: accountID, cache: local?.cache, drafts: local?.drafts ?? [], date: date)
    try Task.checkCancellation()
    let current = try await sync.cachedAccount()
    guard current?.id == account?.id else { throw PlatformError.accountChanged }
    try snapshot.write()
    WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetView.kind)
    try await GistSpotlightIndex.shared.update(snapshot)
  }

  func setTask(id: Int, completed: Bool) async throws {
    try await serially {
      guard let snapshot = try LibrarySnapshot.read(), let accountID = snapshot.accountID,
        snapshot.today.day.filename == DailyNote.filename(),
        let shown = snapshot.today.tasks.first(where: { $0.id == id })
      else { throw PlatformError.staleTask }
      let draft = try await self.todayDraft(accountID: accountID)
      // The task you tapped must still be at its place in your latest text.
      guard let task = FileTask.tasks(in: draft.text).first(where: { $0.id == id }),
        task.title == shown.title
      else { throw PlatformError.staleTask }
      guard task.isChecked != completed else { return }
      try await self.apply(DraftEdit(
        draftID: draft.id, accountID: accountID, expectedGeneration: draft.generation,
        range: NSRange(location: task.markerRange.location + 1, length: 1),
        expectedText: task.isChecked ? "x" : " ", replacement: completed ? "x" : " "))
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
      return .unpublishedGist(accountID: accountID, draftID: draft.id)
    }
  }

  /// Today's file as you last saved it, started the same way the app starts today.
  private func todayDraft(
    accountID: UUID, target: DailyNote.Day = DailyNote.Day()
  ) async throws -> Draft {
    try await validateAccount(accountID)
    let today = try await sync.today(accountID: accountID, target: target)
    if let session = sessions[today.draft.id]?.value {
      guard session.canMutate, await session.waitForLocalSave() else {
        throw PlatformError.editingInProgress
      }
    }
    return try await store.draft(id: today.draft.id, accountID: accountID)
  }

  func validateAccount(_ accountID: UUID) async throws {
    guard let current = try await sync.cachedAccount(), current.id == accountID,
      library?.pendingAccount == nil,
      library?.account == nil || library?.account?.id == accountID
    else { throw PlatformError.accountChanged }
  }

  private func apply(_ edit: DraftEdit) async throws {
    let draft = try await store.draft(id: edit.draftID, accountID: edit.accountID)
    if case .conflict = draft.state { throw PlatformError.editingInProgress }
    let session = sessions[edit.draftID]?.value
    if let session {
      guard !session.file.isRecovery, session.canMutate else {
        throw PlatformError.editingInProgress
      }
      try await session.applyDurableEdit(edit) {
        try await self.validateAccount(edit.accountID)
        return try await self.store.apply(edit)
      }
    } else {
      _ = try await store.apply(edit)
    }
    do {
      if library?.account?.id == edit.accountID {
        try await library?.reloadPlatformState(accountID: edit.accountID)
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
          _ = try await library?.publish(
            draftID: edit.draftID, accountID: edit.accountID, reason: .background,
            expectedGeneration: edit.expectedGeneration + 1,
            shouldPublish: { await MainActor.run { lease.isActive } })
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
