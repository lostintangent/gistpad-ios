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
  private(set) static var shared: PlatformBridge?

  static func install() {
    AppDependencyManager.shared.add { () async throws -> any PlatformActions in
      try await MainActor.run {
        _ = try model()
        return shared!
      }
    }
  }

  static func model() throws -> GistPadModel {
    if let shared { return shared.model }
    guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
      !key.isEmpty, !key.contains("$(")
    else { throw AccountError.invalidConfiguration }
    return connect(
      GistPadModel(
        accounts: GistPadAccountStore(publishableKey: key), drafts: try GistFileDraftStore.open()))
  }

  /// Connects the model to App Intents, widgets and Spotlight.
  static func connect(_ model: GistPadModel) -> GistPadModel {
    shared = PlatformBridge(model: model)
    return model
  }
}

@MainActor
final class PlatformBridge: PlatformActions {
  private let model: GistPadModel
  private var refreshTask: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  /// Starts from the snapshot GistPad launched with, read before the first refresh rewrites it.
  private let spotlight = SpotlightIndex(launchedWith: try? LibrarySnapshot.read())
  private let spotlightSnapshots: AsyncStream<LibrarySnapshot>.Continuation
  private let logger = Logger(subsystem: "dev.gistpad.GistPad", category: "Platform")

  init(model: GistPadModel) {
    self.model = model
    let (snapshots, continuation) = AsyncStream.makeStream(
      of: LibrarySnapshot.self, bufferingPolicy: .bufferingNewest(1))
    spotlightSnapshots = continuation
    indexInSpotlight(snapshots)
    followLibrary()
  }

  /// Widgets, Spotlight and Shortcuts follow the library's account and the drafts on this iPhone,
  /// starting at launch, which catches up on anything that changed while the app wasn't running.
  private func followLibrary() {
    let library = Observations { [weak model] in _ = (model?.account, model?.phase, model?.drafts) }
    Task { [weak self] in
      for await _ in library { self?.scheduleRefresh() }
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
    let account = try await model.localAccount()
    try Task.checkCancellation()
    let snapshot = LibrarySnapshot.make(
      account: account, cache: model.gistCache, drafts: model.drafts, visibleText: Self.noteBody)
    try snapshot.write()
    WidgetCenter.shared.reloadTimelines(ofKind: LauncherWidgetView.kind)
    spotlightSnapshots.yield(snapshot)
  }

  /// Widgets and Spotlight show an accepted change before the intent returns, or soon after.
  private func refreshNow() async {
    do {
      try await refresh()
    } catch {
      logger.error(
        "Accepted change needs presentation refresh: \(String(reflecting: type(of: error)), privacy: .public)")
      scheduleRefresh()
    }
  }

  private static func noteBody(_ source: String) -> String {
    (source as NSString).substring(from: Syntax.contentStart(in: source))
  }

  func noteEntities(for identifiers: [String]) async throws -> [GistEntity] {
    guard let account = try await model.localAccount() else { throw PlatformError.accountChanged }
    let accountID = account.id
    let snapshot = LibrarySnapshot.make(
      account: account, cache: model.gistCache, drafts: model.drafts,
      visibleText: Self.noteBody)
    return snapshot.gists.filter { identifiers.contains($0.id) }.map { entity in
      guard let body = visibleBody(for: entity, accountID: accountID) else { return entity }
      return entity.withBody(body)
    }
  }

  /// The live body of the note on screen, which RootView names as the editor's entity.
  private func visibleBody(for note: GistEntity, accountID: UUID) -> String? {
    guard let fileEditor = model.activeEditor,
      fileEditor.editor.entityIdentifier?.identifier == note.id,
      model.isForeground, model.state.selectedID != nil,
      fileEditor.file.accountID == accountID
    else { return nil }
    return Self.noteBody(fileEditor.editor.text)
  }

  /// Spotlight catches up with the newest snapshot in the background, so nothing waits on it.
  private func indexInSpotlight(_ snapshots: AsyncStream<LibrarySnapshot>) {
    Task { [spotlight, logger] in
      for await snapshot in snapshots {
        do {
          try await spotlight.update(snapshot)
        } catch {
          logger.error(
            "Spotlight update failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
      }
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
      let draft = try await self.current(try await self.model.today(target).nextDraft)
      try await self.append(DailyNote.addition(text, asTask: asTask, after: draft.text), to: draft)
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
      await self.refreshNow()
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
      try await self.append(addition, to: draft)
      return note.withBody(self.visibleBody(for: note, accountID: draft.accountID))
    }
  }

  func updateNote(
    _ note: GistEntity, name: String?, isPinned: Bool?
  ) async throws -> GistEntity {
    try await serially {
      let draft = try await self.noteDraft(for: note)
      let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
      let renames = name != nil && name != String(note.name.characters)
      let changesPin = isPinned != nil && isPinned != note.isPinned
      guard !(renames && changesPin) else { throw PlatformError.unsupportedNoteUpdate }
      if renames, let name {
        guard !name.isEmpty else { throw PlatformError.unsupportedNoteUpdate }
        switch note.link {
        case .gist(let id, nil):
          guard self.model.gistCache?.owned.first(where: { $0.id == id })?.isDailyNote != true else {
            throw PlatformError.unsupportedNoteUpdate
          }
          try await self.model.rename(draft, to: name)
        case .unpublishedGist:
          try await self.model.rename(draft, to: name)
        case .gist, .today, .addToToday, .newGist:
          throw PlatformError.unsupportedNoteUpdate
        }
      }
      if changesPin, let isPinned {
        guard case .gist(let id, _) = note.link else {
          throw PlatformError.unsupportedNoteUpdate
        }
        try await self.model.updatePreferences([.setPinned(gistID: id, pinned: isPinned)])
      }
      await self.refreshNow()
      return note.withMetadata(
        name: renames ? name : nil, isPinned: changesPin ? isPinned : nil)
    }
  }

  private func noteDraft(for note: GistEntity) async throws -> GistFileDraft {
    guard let account = try await model.localAccount(), note.accountID == account.id else {
      throw PlatformError.accountChanged
    }
    switch note.link {
    case .gist(let id, let filename):
      guard let gist = model.gistCache?.owned.first(where: { $0.id == id }),
        let filename = filename ?? gist.defaultMarkdownFilename,
        filename.hasSuffix(".md")
      else { throw DraftError.readOnly }
      if let existing = model.drafts.first(where: {
        $0.gistID == id && $0.filename == filename
      }) {
        return try await current(existing)
      }
      guard gist.markdownFilenames.contains(filename),
        let text = try await model.text(of: filename, in: gist, accountID: account.id)
      else { throw DraftError.notFound }
      return try await current(
        GistFileDraft(accountID: account.id, gist: gist, filename: filename, text: text))
    case .unpublishedGist(let owner, let id):
      guard owner == account.id else { throw PlatformError.accountChanged }
      guard let draft = model.drafts.first(where: { $0.id == id }) else {
        throw DraftError.notFound
      }
      guard draft.gistID == nil else { throw DraftError.changed }
      return try await current(draft)
    case .today, .addToToday, .newGist:
      throw DraftError.notFound
    }
  }

  /// The note as you last saved it, from its open editor once your typing there is saved.
  private func current(_ draft: GistFileDraft) async throws -> GistFileDraft {
    guard let fileEditor = fileEditor(for: draft) else {
      return try await model.current(draft) ?? draft
    }
    guard fileEditor.canEdit, await fileEditor.waitForLocalSave() else {
      throw PlatformError.editingInProgress
    }
    return fileEditor.file.nextDraft
  }

  private func fileEditor(for draft: GistFileDraft) -> GistFileEditor? {
    model.editors.values.first { (fileEditor: GistFileEditor) in
      let file = fileEditor.file.nextDraft
      return file.id == draft.id
        || (file.gistID != nil && file.gistID == draft.gistID && file.filename == draft.filename)
    }
  }

  func validateAccount(_ accountID: UUID) throws {
    guard model.account?.id == accountID else {
      throw PlatformError.accountChanged
    }
  }

  private func append(_ text: String, to draft: GistFileDraft) async throws {
    let accountID = draft.accountID
    if draft.conflict != nil { throw PlatformError.editingInProgress }
    let fileEditor = fileEditor(for: draft)
    if let fileEditor {
      guard !fileEditor.file.isDeletedOnGitHub, fileEditor.canEdit else {
        throw PlatformError.editingInProgress
      }
      try await fileEditor.applyDurableEdit(appending: text, to: draft) {
        try self.validateAccount(accountID)
        return try await self.model.append(text, to: draft)
      }
    } else {
      try validateAccount(accountID)
      _ = try await model.append(text, to: draft)
    }
    await refreshNow()
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
          _ = try await model.publish(draft)
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
