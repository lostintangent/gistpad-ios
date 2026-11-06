import AppIntents
import Editor
import Foundation
import Model
import OSLog
import Platform
import Store
import UIKit
import WidgetKit

@MainActor
extension PlatformBridge {
  private static var services: (model: GistPadModel, bridge: PlatformBridge)?
  static var shared: PlatformBridge? { services?.bridge }

  static func install() {
    AppDependencyManager.shared.add { () async throws -> any DailyNoteActions in
      try await MainActor.run {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
          !key.isEmpty, !key.contains("$(")
        else { throw AccountError.invalidConfiguration }
        _ = try model(publishableKey: key)
        return services!.bridge
      }
    }
  }

  static func model(publishableKey: String) throws -> GistPadModel {
    if let services { return services.model }
    return connect(
      GistPadModel(
        accounts: try GistPadAccountStore(publishableKey: publishableKey),
        drafts: try GistFileDraftStore.open()))
  }

  /// Connects the model to App Intents, widgets and Spotlight.
  static func connect(_ model: GistPadModel) -> GistPadModel {
    services = (model, PlatformBridge(model: model))
    return model
  }
}

@MainActor
final class PlatformBridge: DailyNoteActions {
  private struct WeakEditor {
    weak var value: GistFileEditor?
  }

  private let model: GistPadModel
  private var visibleEditor: WeakEditor?
  private var visibleNoteID: String?
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  /// Starts from the snapshot GistPad launched with, read before the first refresh rewrites it.
  private let spotlight = GistSpotlightIndex(launchedWith: try? LibrarySnapshot.read())
  private var spotlightSnapshot: LibrarySnapshot?
  private var spotlightTask: Task<Void, Never>?
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "SystemIntegration")

  init(model: GistPadModel) {
    self.model = model
    followLibrary()
    // Launch also catches up on anything that changed while the app wasn't running.
    scheduleRefresh()
  }

  /// Widgets, Spotlight and Shortcuts follow the library's account and the drafts on this iPhone.
  private func followLibrary() {
    withObservationTracking {
      _ = (model.account, model.pendingAccount, model.localDrafts)
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleRefresh()
        self?.followLibrary()
      }
    }
  }

  func setVisibleNote(_ id: String?, fileEditor: GistFileEditor) {
    if let id {
      visibleEditor = WeakEditor(value: fileEditor)
      visibleNoteID = id
    } else if visibleEditor?.value === fileEditor {
      visibleEditor = nil
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
    let account = model.pendingAccount == nil ? try await model.localAccount() : nil
    try Task.checkCancellation()
    let snapshot = LibrarySnapshot.make(
      account: account, cache: account == nil ? nil : model.gistCache,
      drafts: account == nil ? [] : model.localDrafts, visibleText: Self.noteBody)
    try snapshot.write()
    WidgetCenter.shared.reloadTimelines(ofKind: LauncherWidgetView.kind)
    indexInSpotlight(snapshot)
  }

  nonisolated private static func noteBody(_ source: String) -> String {
    (source as NSString).substring(from: Syntax.contentStart(in: source))
  }

  func noteEntities(for identifiers: [String]) async throws -> [GistEntity] {
    guard let account = try await model.localAccount() else { throw PlatformError.accountChanged }
    let accountID = account.id
    let snapshot = LibrarySnapshot.make(
      account: account, cache: model.gistCache, drafts: model.localDrafts,
      visibleText: Self.noteBody)
    return snapshot.gists.filter { identifiers.contains($0.id) }.map { entity in
      guard let body = visibleBody(for: entity, accountID: accountID) else { return entity }
      return entity.withBody(body)
    }
  }

  private func visibleBody(for note: GistEntity, accountID: UUID) -> String? {
    guard note.id == visibleNoteID, let fileEditor = visibleEditor?.value,
      model.isForeground, model.activeEditor === fileEditor,
      model.state.selectedID != nil,
      fileEditor.draft.accountID == accountID
    else { return nil }
    return Self.noteBody(fileEditor.editor.text)
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
      guard let accountID = try await self.model.localAccount()?.id else {
        throw PlatformError.accountChanged
      }
      // Today's file as you last saved it, started the same way the app starts today.
      let draft = try await self.current(try await self.model.today(target).draft)
      try await self.apply(.addToToday(text, asTask: asTask, to: draft))
      return draft.gistID.map { .gist(id: $0, filename: draft.filename) }
        ?? .unpublishedGist(accountID: accountID, draftID: draft.id)
    }
  }

  func createNote(name: String, content: String?) async throws -> GistEntity {
    try await serially {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw PlatformError.emptyNoteName }
      guard let accountID = try await self.model.localAccount()?.id else {
        throw PlatformError.accountChanged
      }
      let draft = try await self.model.createGist(named: name, text: content)
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
      let model = self.model
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
          try await model.rename(gistID: id, to: name)
        case .unpublishedGist:
          try await model.rename(draft, to: name)
        case .gist, .today, .addToToday, .newGist:
          throw PlatformError.unsupportedNoteUpdate
        }
      }
      if changesPin {
        guard let isPinned else { throw PlatformError.unsupportedNoteUpdate }
        guard case .gist(let id, _) = note.link else {
          throw PlatformError.unsupportedNoteUpdate
        }
        try await model.updatePreferences([.setPinned(gistID: id, pinned: isPinned)])
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
    guard let account = try await model.localAccount(), note.accountID == account.id else {
      throw PlatformError.accountChanged
    }
    switch note.link {
    case .gist(let id, let filename):
      guard let gist = model.gistCache?.owned.first(where: { $0.id == id }),
        let filename = filename ?? gist.defaultMarkdownFilename,
        filename.hasSuffix(".md")
      else { throw DraftError.readOnly }
      if let existing = model.localDrafts.first(where: {
        $0.gistID == id && $0.filename == filename
      }) {
        return try await current(existing)
      }
      guard gist.markdownFilenames.contains(filename),
        let text = try await model.text(of: filename, in: gist, accountID: account.id)
      else { throw DraftError.notFound }
      guard let userID = account.githubUserID else { throw AccountError.reconnectGitHub }
      return try await current(
        Draft(accountID: account.id, githubUserID: userID, gist: gist, filename: filename, text: text))
    case .unpublishedGist(let owner, let id):
      guard owner == account.id else { throw PlatformError.accountChanged }
      guard let draft = model.localDrafts.first(where: { $0.id == id }) else {
        throw DraftError.notFound
      }
      guard draft.gistID == nil else { throw DraftError.staleGeneration }
      return try await current(draft)
    case .today, .addToToday, .newGist:
      throw DraftError.notFound
    }
  }

  /// The note as you last saved it, from its open editor once your typing there is saved.
  private func current(_ draft: Draft) async throws -> Draft {
    guard let fileEditor = fileEditor(for: draft) else { return try await model.current(draft) }
    guard fileEditor.canMutate, await fileEditor.waitForLocalSave() else {
      throw PlatformError.editingInProgress
    }
    return fileEditor.draft
  }

  private func fileEditor(for draft: Draft) -> GistFileEditor? {
    model.editors.values.first { (fileEditor: GistFileEditor) in
      fileEditor.draft.id == draft.id
        || (fileEditor.draft.gistID != nil && fileEditor.draft.gistID == draft.gistID
          && fileEditor.draft.filename == draft.filename)
    }
  }

  func validateAccount(_ accountID: UUID) throws {
    guard model.account?.id == accountID, model.pendingAccount == nil else {
      throw PlatformError.accountChanged
    }
  }

  private func apply(_ edit: DraftEdit) async throws {
    let accountID = edit.draft.accountID
    if case .conflict = edit.draft.state { throw PlatformError.editingInProgress }
    let fileEditor = fileEditor(for: edit.draft)
    if let fileEditor {
      guard !fileEditor.file.isRecovery, fileEditor.canMutate else {
        throw PlatformError.editingInProgress
      }
      try await fileEditor.applyDurableEdit(edit) {
        try self.validateAccount(accountID)
        return try await self.model.apply(edit)
      }
    } else {
      try validateAccount(accountID)
      _ = try await model.apply(edit)
    }
    do {
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
        if let fileEditor {
          await fileEditor.publish(reason: .background, shouldContinue: { lease.isActive })
        } else {
          _ = try await model.publish(edit.draft)
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
