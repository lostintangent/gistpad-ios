import Foundation
import Store

// A file opens at once from what this iPhone has, and reads GitHub only for what it lacks.

/// A file on its way to the detail column, and why it couldn't open if it failed.
public struct Opening: Equatable {
  public enum Request: Codable, Equatable {
    case gist(id: String, filename: String? = nil, rowID: String? = nil)
    case draft(id: UUID, rowID: String? = nil)
    case today(DailyNote.Day = DailyNote.Day(), focusesEditor: Bool = true)
    case new

    /// Creating a gist or starting the day puts the caret in it.
    var focusesEditor: Bool {
      switch self {
      case .new: true
      case .today(_, let focusesEditor): focusesEditor
      case .gist, .draft: false
      }
    }

    /// Restoring today without asking for it leaves the library showing.
    var revealsDetail: Bool {
      if case .today(_, false) = self { false } else { true }
    }
  }

  public let request: Request
  public let rowID: String
  public let title: String
  public var failure: String?

  public var filename: String? {
    switch request {
    case .gist(_, let filename, _): filename
    case .today(let target, _): target.filename
    case .draft, .new: nil
    }
  }
}

extension GistPadModel {
  public var visibleFile: GistFile? {
    if let opening { return opening.failure == nil ? cachedFile(rowID: opening.rowID) : nil }
    guard let selected = state.selectedID else { return loadedFile }
    if loadedRowID == selected { return loadedFile }
    return cachedFile(rowID: selected)
  }

  /// The editor for the file in the detail column.
  public var activeEditor: GistFileEditor? {
    guard let file = visibleFile else { return nil }
    return editors.values.first { $0.file.refersToSameFile(as: file) }
  }

  public var openingTitle: String? {
    if let opening { return opening.title }
    guard let selected = state.selectedID, selected != loadedRowID else {
      return nil
    }
    return placeholder(for: request(forRow: selected)).title
  }

  /// Opens a library row, at once when its file is already on this iPhone.
  public func open(rowID id: String) {
    guard account != nil, phase.switchingTo == nil else {
      openError = String(localized: "Reconnect GitHub to open this gist.")
      return
    }
    fileRequest = UUID()
    openError = nil
    if let file = cachedFile(rowID: id) { return present(file) }
    opening = placeholder(for: request(forRow: id))
    state.selectedID = id
    let request = fileRequest
    Task {
      guard request == fileRequest else { return }
      await open(self.request(forRow: id))
    }
  }

  /// The draft a row shows when GitHub doesn't list its gist.
  func draft(forRow rowID: String) -> GistFileDraft? {
    UUID(uuidString: rowID).flatMap { id in drafts.first { $0.id == id } }
  }

  func cachedFile(rowID: String) -> GistFile? {
    switch request(forRow: rowID) {
    case .draft(let id, _): drafts.first { $0.id == id }.map(localFile)
    case .gist(let id, let filename, _): cachedFile(gistID: id, filename: filename)
    case .today, .new: nil
    }
  }

  private func cachedFile(gistID: String, filename: String? = nil) -> GistFile? {
    guard let account, phase.switchingTo == nil else { return nil }
    let gist = gistCache?.gists.first { $0.id == gistID }
    let selectedFilename: String?
    if let filename {
      selectedFilename = filename
    } else if let gist {
      guard gist.truncated != true || gist.isDailyNote else { return nil }
      selectedFilename = gist.isDailyNote ? DailyNote.filename() : gist.defaultMarkdownFilename
    } else {
      let candidates = drafts.filter { $0.gistID == gistID }
      selectedFilename = candidates.count == 1 ? candidates.first?.filename : nil
    }
    guard let selectedFilename, selectedFilename.hasSuffix(".md") else { return nil }
    if let draft = drafts.first(where: {
      $0.accountID == account.id && $0.gistID == gistID && $0.filename == selectedFilename
    }) {
      return localFile(draft)
    }
    guard let gist, let text = gistCache?.text(of: selectedFilename, in: gist) else { return nil }
    return GistFile(
      accountID: account.id, gist: gist, filename: selectedFilename,
      published: GitHubVersion(text: text, revision: gist.revision))
  }

  private func localFile(_ draft: GistFileDraft) -> GistFile {
    let gist = gistCache?.gists.first { $0.id == draft.gistID }
    return GistFile(draft: draft, gist: gist, isDeletedOnGitHub: draft.gistID != nil && gist == nil)
  }

  func request(forRow id: String) -> Opening.Request {
    if let draft = draft(forRow: id) {
      // A file that never reached GitHub only exists on this iPhone.
      guard let gistID = draft.gistID, draft.base != nil else { return .draft(id: draft.id, rowID: id) }
      return .gist(id: gistID, filename: draft.filename, rowID: id)
    }
    if let row = state.gists.first(where: { $0.id == id }), let gistID = row.gistID,
      let filename = row.filename
    {
      return .gist(id: gistID, filename: filename, rowID: id)
    }
    return .gist(id: id, rowID: id)
  }

  private func placeholder(for request: Opening.Request) -> Opening {
    let (rowID, title): (String, String?) =
      switch request {
      case .gist(let id, _, let rowID):
        (rowID ?? id, gistCache?.gists.first { $0.id == id }?.displayName)
      case .draft(let id, let rowID):
        (rowID ?? id.uuidString, drafts.first { $0.id == id }?.newGistName)
      case .today(let target, _): ("today/\(target.filename)", String(localized: "Today"))
      case .new: ("new", String(localized: "Untitled"))
      }
    return .init(
      request: request, rowID: rowID,
      title: state.gists.first { $0.id == rowID }?.title ?? title
        ?? String(localized: "Gist"))
  }

  func present(_ file: GistFile, as request: Opening.Request? = nil) {
    opening = nil
    loadedFile = file
    loadedRowID = unfilteredRowID(for: file) ?? file.rowID
    state.selectedID = loadedRowID
    if file.isDeletedOnGitHub { openError = Self.recoveryMessage }
    remember(file.request)
    let fileEditor: GistFileEditor
    if let open = editors.values.first(where: { $0.file.refersToSameFile(as: file) }) {
      fileEditor = open
    } else {
      fileEditor = GistFileEditor(file: file, model: self)
      editors[file.id] = fileEditor
    }
    fileEditor.present(
      file, focusesEditor: request?.focusesEditor ?? false,
      revealsDetail: request?.revealsDetail ?? true)
  }

  func unfilteredRowID(for file: GistFile) -> String? {
    state.gists.first {
      $0.id == file.id.uuidString
        || ($0.gistID != nil && $0.gistID == file.gistID
          && ($0.filename == nil || $0.filename == file.filename))
    }?.id
  }

  /// Opens a file in the detail column. A newer open supersedes this one, but keeps any file this
  /// one created.
  public func open(_ request: Opening.Request) async {
    guard let account, phase.switchingTo == nil else {
      openError = String(localized: "Reconnect GitHub to open this gist.")
      return
    }
    let focusesEditor = request.focusesEditor
    if focusesEditor {
      guard !isCreating else { return }
      isCreating = true
    }
    let token = UUID()
    fileRequest = token
    openError = nil
    opening = placeholder(for: request)
    defer {
      if focusesEditor { isCreating = false }
      if token == fileRequest, opening?.failure == nil { opening = nil }
    }
    do {
      let opened = try await file(for: request, account: account)
      guard token == fileRequest else { return }
      present(opened, as: request)
    } catch is CancellationError {
      if token == fileRequest { state.selectedID = loadedRowID }
    } catch {
      guard token == fileRequest else { return }
      report(error, operation: "open")
      if case .new = request {
        openError = error.localizedDescription
      } else {
        opening?.failure = error.localizedDescription
        state.selectedID = opening?.rowID
      }
    }
  }

  func file(
    for request: Opening.Request, account: GistPadAccount
  ) async throws -> GistFile {
    switch request {
    case .gist(let id, let filename, _):
      if let cached = cachedFile(gistID: id, filename: filename) { return cached }
      let gist = try await gist(id: id, accountID: account.id)
      let filenames = gist.markdownFilenames
      let selected: String? =
        if let filename {
          filenames.contains(filename) ? filename : nil
        } else if gist.isDailyNote {
          filenames.first { $0 == DailyNote.filename() }
        } else {
          gist.defaultMarkdownFilename
        }
      guard let selected else { throw GitHubClientError.missingFile }
      guard let text = try await text(of: selected, in: gist, accountID: account.id) else {
        throw GitHubClientError.missingFile
      }
      // The read is cached on this iPhone, so the note opens from here next time.
      try await reloadLocalState(accountID: account.id)
      let published = GistFile(
        accountID: account.id, gist: gist, filename: selected,
        published: GitHubVersion(text: text, revision: gist.revision))
      if let draft = try await current(published.nextDraft) {
        return GistFile(draft: draft, gist: gist)
      }
      return published
    case .draft(let id, _):
      if !drafts.contains(where: { $0.id == id }) {
        try await reloadLocalState(accountID: account.id)
      }
      guard let draft = drafts.first(where: { $0.id == id }) else { throw DraftError.notFound }
      return localFile(draft)
    case .today(let target, _):
      let daily = gistCache?.owned.first(where: \.isDailyNote)
      let day = DailyNote(day: target, cache: gistCache, drafts: drafts)
      if let draft = drafts.first(where: { $0.id == day.draftID }) {
        return GistFile(draft: draft, gist: daily)
      }
      if let daily, let cached = cachedFile(gistID: daily.id, filename: target.filename) {
        return cached
      }
      return try await today(target)
    case .new:
      return GistFile(draft: GistFileDraft(accountID: account.id))
    }
  }

  /// Closes a new note you left without writing in it, since nothing of it was kept.
  func close(_ fileEditor: GistFileEditor) {
    let file = fileEditor.file
    guard !fileEditor.hasUnpublishedChanges, file.gistID == nil,
      state.selectedID == nil || visibleFile?.id != file.id
    else { return }
    editors[file.id] = nil
    if loadedFile?.id == file.id {
      loadedFile = nil
      loadedRowID = nil
    }
  }

  public func showLibrary() {
    fileRequest = UUID()
    opening = nil
    state.selectedID = nil
  }

  func remember(_ request: Opening.Request) {
    guard let account else { return }
    defaults.set(try? JSONEncoder().encode(request), forKey: Self.lastOpenedKey(account.id))
  }

  /// The file this account last had open. One that can't be read is simply forgotten.
  func lastOpened(accountID: UUID) -> Opening.Request? {
    (defaults.object(forKey: Self.lastOpenedKey(accountID)) as? Data).flatMap {
      try? JSONDecoder().decode(Opening.Request.self, from: $0)
    }
  }

  /// Keeps its original name so a remembered file can survive an update.
  static func lastOpenedKey(_ accountID: UUID) -> String {
    "notebook.selection.\(accountID.uuidString)"
  }

  /// Reopens the file you last had open. With nothing remembered, nothing opens, because a file
  /// only starts when you ask for it.
  func restoreLastOpened() async {
    guard loadedFile == nil, state.selectedID == nil, opening == nil, let account,
      phase.switchingTo == nil, let saved = lastOpened(accountID: account.id)
    else { return }
    if case .draft(let id, _) = saved, !drafts.contains(where: { $0.id == id }) { return }
    await open(saved)
  }

  private static let recoveryMessage = String(
    localized:
      "This gist was deleted on GitHub. Your unpublished text is kept on this iPhone.")
}

extension GistFileEditor {
  /// Changes whenever an open asks for the caret, so the screen prepares the file again.
  public var activationID: String { focusRequest?.uuidString ?? file.id.uuidString }

  public func requestCreationFocus() {
    guard let request = focusRequest, request != lastFocusRequest, canMutate else { return }
    lastFocusRequest = request
    mode = .edit
    editor.requestFocusAtEnd()
  }

  /// Shows the file as it opens again: with its latest gist, and asking for the caret when the
  /// open did.
  func present(_ incoming: GistFile, focusesEditor: Bool, revealsDetail: Bool) {
    guard incoming.accountID == file.accountID,
      incoming.gist?.id == file.gist?.id, incoming.filename == file.filename
    else { return }
    focusRequest = focusesEditor ? UUID() : nil
    self.revealsDetail = revealsDetail
    if let gist = incoming.gist { file.gist = gist }
  }
}
