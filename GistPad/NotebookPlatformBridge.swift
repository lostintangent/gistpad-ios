import AppIntents
import Foundation
import GistPadPlatform
import GistPadSync
import OSLog
import UIKit
import WidgetKit

@MainActor
enum NotebookPlatformBootstrap {
  private static var services: (model: NotebookModel, bridge: NotebookPlatformBridge)?
  static var bridge: NotebookPlatformBridge? { services?.bridge }

  static func install() {
    AppDependencyManager.shared.add { () async throws -> any NotebookIntentServing in
      try await MainActor.run {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
          !key.isEmpty, !key.contains("$(")
        else { throw AccountError.invalidConfiguration }
        _ = try notebook(publishableKey: key)
        return services!.bridge
      }
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
}

@MainActor
final class NotebookPlatformBridge: NotebookIntentServing {
  private struct WeakSession {
    weak var value: NotebookSessionController?
  }

  private let provider: LiveNotebookProvider
  private let store: DraftStore
  private weak var notebook: NotebookModel?
  private var sessions: [UUID: WeakSession] = [:]
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SystemIntegration")

  init(provider: LiveNotebookProvider, store: DraftStore, notebook: NotebookModel) {
    self.provider = provider
    self.store = store
    self.notebook = notebook
    followNotebook()
  }

  /// Widgets, Spotlight and Shortcuts follow the notebook's account and the drafts on this iPhone.
  private func followNotebook() {
    withObservationTracking {
      _ = (notebook?.account, notebook?.pendingAccount, notebook?.localDrafts)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleRefresh()
        self?.followNotebook()
      }
    }
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
    let shared = try SharedNotebookStore()
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
    let snapshot = NotebookSystemSnapshot.make(
      accountID: accountID, cache: local?.library, drafts: local?.drafts ?? [], date: date)
    try Task.checkCancellation()
    let current = try await provider.cachedAccount()
    guard current?.id == account?.id else { throw NotebookPlatformError.accountChanged }
    try shared.write(snapshot)
    WidgetCenter.shared.reloadTimelines(ofKind: TodayWidgetView.kind)
    try await NotebookEntityIndex.shared.update(snapshot)
  }

  func setTask(id: Int, completed: Bool) async throws {
    try await serially {
      guard let snapshot = try SharedNotebookStore().read(), let accountID = snapshot.accountID,
        snapshot.today.day.filename == GistConventions.todayFilename(),
        let shown = snapshot.today.tasks.first(where: { $0.id == id })
      else { throw NotebookPlatformError.staleTask }
      let draft = try await self.todayDraft(accountID: accountID)
      // The task you tapped must still be at its place in your latest text.
      guard let task = FileTask.tasks(in: draft.text).first(where: { $0.id == id }),
        task.title == shown.title
      else { throw NotebookPlatformError.staleTask }
      guard task.isChecked != completed else { return }
      try await self.apply(DraftEdit(
        draftID: draft.id, accountID: accountID, expectedGeneration: draft.generation,
        range: NSRange(location: task.markerRange.location + 1, length: 1),
        expectedText: task.isChecked ? "x" : " ", replacement: completed ? "x" : " "))
    }
  }

  @discardableResult
  func addToToday(
    text: String, asTask: Bool, target: DailyNoteTarget
  ) async throws -> NotebookRoute {
    try await serially {
      guard let accountID = try await self.provider.cachedAccount()?.id else {
        throw NotebookPlatformError.accountChanged
      }
      let draft = try await self.todayDraft(accountID: accountID, target: target)
      try await self.apply(.addToToday(text, asTask: asTask, to: draft))
      return .draft(accountID: accountID, draftID: draft.id)
    }
  }

  /// Today's file as you last saved it, started the same way the app starts today.
  private func todayDraft(
    accountID: UUID, target: DailyNoteTarget = DailyNoteTarget()
  ) async throws -> DraftSnapshot {
    try await validateAccount(accountID)
    let today = try await provider.today(accountID: accountID, target: target)
    if let session = sessions[today.draft.id]?.value {
      guard session.canMutate, await session.waitForLocalSave() else {
        throw NotebookPlatformError.editingInProgress
      }
    }
    return try await store.draft(id: today.draft.id, accountID: accountID)
  }

  func validateAccount(_ accountID: UUID) async throws {
    guard let current = try await provider.cachedAccount(), current.id == accountID,
      notebook?.pendingAccount == nil,
      notebook?.account == nil || notebook?.account?.id == accountID
    else { throw NotebookPlatformError.accountChanged }
  }

  private func apply(_ edit: DraftEdit) async throws {
    let draft = try await store.draft(id: edit.draftID, accountID: edit.accountID)
    guard draft.attemptedGeneration == nil else { throw NotebookPlatformError.editingInProgress }
    if case .conflict = draft.state { throw NotebookPlatformError.editingInProgress }
    let controller = sessions[edit.draftID]?.value
    if let controller {
      guard !controller.document.isRecovery, controller.canMutate else {
        throw NotebookPlatformError.editingInProgress
      }
      try await controller.applyDurableEdit(edit) {
        try await self.validateAccount(edit.accountID)
        return try await self.store.apply(edit)
      }
    } else {
      _ = try await store.apply(edit)
    }
    do {
      if notebook?.account?.id == edit.accountID {
        try await notebook?.reloadPlatformState(accountID: edit.accountID)
      }
      try await refresh()
    } catch {
      logger.error(
        "Accepted system edit needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
      scheduleRefresh()
    }
    if UIApplication.shared.applicationState != .active {
      let lease = NotebookBackgroundLease()
      defer { lease.end() }
      guard lease.isActive else {
        logger.info("System edit is durable. No background publication lease is available.")
        return
      }
      do {
        if let controller {
          await controller.publish(reason: .background, shouldContinue: { lease.isActive })
        } else {
          _ = try await notebook?.publish(
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
