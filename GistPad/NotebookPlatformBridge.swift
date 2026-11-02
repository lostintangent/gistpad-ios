import Foundation
import GistPadPlatform
import GistPadSync
import OSLog
import UIKit
import WidgetKit

@MainActor
enum NotebookPlatformBootstrap {
  private static var services: (model: NotebookModel, bridge: NotebookPlatformBridge)?

  static func install() {
    NotebookIntentRuntime.configure {
      guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
        !key.isEmpty, !key.contains("$(")
      else { throw AccountError.invalidConfiguration }
      _ = try notebook(publishableKey: key)
      guard let bridge = services?.bridge else { throw NotebookPlatformError.serviceUnavailable }
      return bridge
    }
  }

  static func notebook(publishableKey: String) throws -> NotebookModel {
    if let services { return services.model }
    let store = try DraftStore.open()
    let provider = LiveNotebookProvider(
      accounts: try AccountService(publishableKey: publishableKey), drafts: store)
    return connect(provider, store: store, selections: NotebookSelectionStore(defaults: .standard))
  }

  /// Builds the notebook and connects it to App Intents, widgets and Spotlight.
  static func connect(
    _ provider: LiveNotebookProvider, store: DraftStore, selections: NotebookSelectionStore
  ) -> NotebookModel {
    let model = NotebookModel(provider: provider, selections: selections)
    services = (model, NotebookPlatformBridge(provider: provider, store: store, notebook: model))
    return model
  }

  static func register(_ controller: NotebookSessionController, notebook: NotebookModel) {
    guard services?.model === notebook else { return }
    services?.bridge.register(controller)
  }

  static func scheduleRefresh() { services?.bridge.scheduleRefresh() }
}

@MainActor
final class NotebookPlatformBridge: NotebookIntentServing {
  private struct WeakSession {
    weak var value: NotebookSessionController?
  }

  private let provider: any NotebookProviding
  private let store: DraftStore
  private let suppliedSharedStore: SharedNotebookStore?
  private let isBackgrounded: @MainActor () -> Bool
  private weak var notebook: NotebookModel?
  private var sessions: [UUID: WeakSession] = [:]
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, any Error>?
  private var operationID: UUID?
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SystemIntegration")

  init(
    provider: any NotebookProviding, store: DraftStore, notebook: NotebookModel,
    sharedStore: SharedNotebookStore? = nil,
    isBackgrounded: @escaping @MainActor () -> Bool = {
      UIApplication.shared.applicationState != .active
    }
  ) {
    self.provider = provider
    self.store = store
    self.notebook = notebook
    suppliedSharedStore = sharedStore
    self.isBackgrounded = isBackgrounded
  }

  func register(_ controller: NotebookSessionController) {
    sessions = sessions.filter { $0.value.value != nil }
    sessions[controller.draft.id] = WeakSession(value: controller)
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
          "System notebook refresh failed: \(String(reflecting: type(of: error)), privacy: .public)")
      }
    }
  }

  func refresh(date: Date = .now) async throws {
    let shared = try sharedStore()
    let account = try await provider.cachedAccount()
    let accountID =
      notebook?.pendingAccount == nil
        && (notebook?.account == nil || notebook?.account?.id == account?.id)
      ? account?.id : nil
    let local: NotebookLocalState?
    if let accountID {
      local = try await provider.localState(accountID: accountID)
    } else {
      local = nil
    }
    var drafts = local?.drafts ?? []
    let filename = GistConventions.todayFilename(date: date)
    if let account, account.id == accountID, let userID = account.githubUserID,
      let cache = local?.library, let daily = cache.owned.first(where: \.isDailyNote),
      daily.owner?.id == userID, let text = cache.content(gist: daily, filename: filename),
      !drafts.contains(where: { $0.gistID == daily.id && $0.filename == filename })
    {
      let draft = try await store.openDraft(
        accountID: account.id, githubUserID: userID, gistID: daily.id, filename: filename,
        description: daily.description ?? "", content: text, revision: daily.revision)
      drafts.append(draft)
    }
    let snapshot = try NotebookSystemSnapshot.make(
      accountID: accountID, cache: local?.library, drafts: drafts, date: date)
    try Task.checkCancellation()
    let current = try await provider.cachedAccount()
    guard current?.id == account?.id else { throw NotebookPlatformError.accountChanged }
    try shared.write(snapshot)
    WidgetCenter.shared.reloadTimelines(ofKind: "GistPadToday")
    try await NotebookEntityIndex.shared.update(snapshot)
  }

  func setTask(id: String, completed: Bool) async throws {
    try await serially {
      let snapshot = try self.sharedStore().read()
      guard let accountID = snapshot?.accountID,
        let today = snapshot?.today,
        today.filename == GistConventions.todayFilename(),
        let task = today.tasks.first(where: { $0.id == id })
      else { throw NotebookPlatformError.staleTask }
      try await self.validateAccount(accountID)
      if task.isCompleted == completed { return }
      let command = task.command(accountID: accountID, completed: completed)
      try await self.apply(command)
    }
  }

  @discardableResult
  func addToToday(
    text: String, asTask: Bool, target: DailyNoteTarget
  ) async throws -> NotebookRoute {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NotebookPlatformError.emptyText
    }
    return try await serially {
      guard let account = try await self.provider.cachedAccount() else {
        throw NotebookPlatformError.accountChanged
      }
      try await self.validateAccount(account.id)
      let today = try await self.provider.today(accountID: account.id, target: target)
      try await self.validateAccount(account.id)
      if let gist = today.gist {
        guard gist.owner?.id == today.draft.githubUserID else { throw DraftError.readOnly }
        let cache = try await self.store.cachedLibrary(accountID: account.id)
        var owned = cache?.owned ?? []
        owned.removeAll { $0.id == gist.id }
        owned.append(gist)
        owned.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        try await self.store.cacheLibrary(
          owned: owned, starred: cache?.starred ?? [], preferences: account.preferences,
          accountID: account.id)
        try await self.store.cacheGist(gist, accountID: account.id)
      }
      if let session = self.sessions[today.draft.id]?.value {
        guard session.canMutate, await session.waitForLocalSave() else {
          throw NotebookPlatformError.editingInProgress
        }
      }
      let draft = try await self.store.draft(id: today.draft.id, accountID: account.id)
      let command = try TodayAppend.command(draft: draft, text: text, asTask: asTask)
      try await self.apply(command)
      return .draft(accountID: account.id, draftID: draft.id)
    }
  }

  func validateAccount(_ accountID: UUID) async throws {
    guard let current = try await provider.cachedAccount(), current.id == accountID,
      notebook?.pendingAccount == nil,
      notebook?.account == nil || notebook?.account?.id == accountID
    else { throw NotebookPlatformError.accountChanged }
  }

  private func apply(_ command: SharedDraftCommand) async throws {
    try await validateAccount(command.accountID)
    let draft = try await store.draft(id: command.draftID, accountID: command.accountID)
    guard draft.attemptedGeneration == nil else { throw NotebookPlatformError.editingInProgress }
    if case .conflict = draft.state { throw NotebookPlatformError.editingInProgress }
    let controller = sessions[command.draftID]?.value
    if let controller {
      guard !controller.document.isRecovery, controller.canMutate else {
        throw NotebookPlatformError.editingInProgress
      }
      try await controller.applyDurableEdit(command) {
        try await self.validateAccount(command.accountID)
        return try await self.store.apply(command)
      }
    } else {
      _ = try await store.apply(command)
    }
    do {
      if notebook?.account?.id == command.accountID {
        try await notebook?.reloadPlatformState(accountID: command.accountID)
      }
      try await refresh()
    } catch {
      logger.error(
        "Accepted system edit needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
      scheduleRefresh()
    }
    if isBackgrounded() {
      let lease = NotebookBackgroundLease()
      defer { lease.end() }
      guard lease.isActive else {
        logger.info("System edit is durable. No background publication lease is available.")
        return
      }
      do {
        if let controller {
          await controller.publish(reason: .background, shouldContinue: { lease.isActive })
        } else if let notebook {
          _ = try await notebook.publish(
            draftID: command.draftID, accountID: command.accountID, reason: .background,
            expectedGeneration: command.expectedGeneration + 1,
            shouldPublish: { await MainActor.run { lease.isActive } })
        } else {
          _ = try await provider.publish(
            draftID: command.draftID, accountID: command.accountID, reason: .background,
            expectedGeneration: command.expectedGeneration + 1,
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
    let id = UUID()
    let task = Task {
      if let previous { _ = await previous.result }
      try Task.checkCancellation()
      return try await action()
    }
    operation = Task { _ = try await task.value }
    operationID = id
    defer {
      if operationID == id {
        operation = nil
        operationID = nil
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func sharedStore() throws -> SharedNotebookStore {
    if let suppliedSharedStore { return suppliedSharedStore }
    return try SharedNotebookStore()
  }
}
