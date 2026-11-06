import Foundation
import Sync

// A file opens at once from what this iPhone has, and reads GitHub only for what it lacks.

/// A file on its way to the detail column, and why it couldn't open if it failed.
public struct Opening: Equatable {
  public enum Request: Equatable {
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

    /// The saved file this opens, so deleting it stops the opening.
    var selection: FileReference? {
      switch self {
      case .gist(let id, let filename, _): .init(gistID: id, filename: filename ?? "", draftID: nil)
      case .draft(let id, _): .init(gistID: nil, filename: "", draftID: id)
      case .today, .new: nil
      }
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

extension Library {
  public var visibleFile: File? {
    if let opening { return opening.failure == nil ? cachedFile(rowID: opening.rowID) : nil }
    guard let selected = state.selectedID else { return loadedFile }
    if loadedFile?.rowID == selected { return loadedFile }
    return cachedFile(rowID: selected)
  }

  /// The editor for the file in the detail column.
  public var activeSession: FileSession? {
    guard let file = visibleFile else { return nil }
    return sessions.values.first { $0.file.refersToSameFile(as: file) }
  }

  public var openingTitle: String? {
    if let opening { return opening.title }
    guard let selected = state.selectedID, selected != loadedFile?.rowID else {
      return nil
    }
    return placeholder(for: request(forRow: selected)).title
  }

  @discardableResult
  func beginOpeningRow(id: String) -> Bool {
    guard account != nil, pendingAccount == nil else {
      openError = String(localized: "Reconnect GitHub to open this gist.")
      return false
    }
    fileRequest = UUID()
    openError = nil
    if let file = cachedFile(rowID: id) {
      present(file)
      return true
    }
    opening = placeholder(for: request(forRow: id))
    state.selectedID = id
    return false
  }

  /// Opens a library row, at once when its file is already on this iPhone.
  public func select(rowID id: String) {
    guard !beginOpeningRow(id: id), opening?.rowID == id else { return }
    let request = fileRequest
    Task {
      guard request == fileRequest else { return }
      await openRow(id: id)
    }
  }

  func rowSelection(for rowID: String) -> FileReference? {
    if let id = UUID(uuidString: rowID), let draft = localDrafts.first(where: { $0.id == id }) {
      return .init(gistID: draft.gistID, filename: draft.filename, draftID: id)
    }
    if let row = state.gists.first(where: { $0.id == rowID }),
      let gistID = row.gistID, let filename = row.filename
    {
      return .init(gistID: gistID, filename: filename, draftID: nil)
    }
    return nil
  }

  func cachedFile(rowID: String) -> File? {
    if let target = rowSelection(for: rowID) {
      if let draftID = target.draftID, let draft = localDrafts.first(where: { $0.id == draftID }) {
        return localFile(draft, rowID: rowID)
      }
      if let gistID = target.gistID {
        return cachedFile(gistID: gistID, filename: target.filename, rowID: rowID)
      }
      return nil
    }
    return cachedFile(gistID: rowID, rowID: rowID)
  }

  private func cachedFile(
    gistID: String, filename: String? = nil, rowID: String? = nil
  ) -> File? {
    guard let account, pendingAccount == nil else { return nil }
    let gist = cachedLibrary?.gists.first { $0.id == gistID }
    let selectedFilename: String?
    if let filename {
      selectedFilename = filename
    } else if let gist {
      guard gist.truncated != true || gist.isDailyNote else { return nil }
      selectedFilename = gist.isDailyNote ? DailyNote.filename() : gist.defaultMarkdownFilename
    } else {
      let candidates = localDrafts.filter { $0.gistID == gistID }
      selectedFilename = candidates.count == 1 ? candidates.first?.filename : nil
    }
    guard let selectedFilename, selectedFilename.hasSuffix(".md") else { return nil }
    if let draft = localDrafts.first(where: {
      $0.accountID == account.id && $0.gistID == gistID && $0.filename == selectedFilename
    }) {
      return localFile(draft, rowID: rowID)
    }
    guard let gist, let userID = account.githubUserID,
      let text = cachedLibrary?.content(gist: gist, filename: selectedFilename)
    else { return nil }
    var file = File(
      draft: Draft(
        accountID: account.id, githubUserID: userID, gist: gist, filename: selectedFilename,
        text: text),
      gist: gist)
    file.libraryRowID = rowID
    return file
  }

  private func localFile(_ draft: Draft, rowID: String?) -> File {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
    var file = File(
      draft: draft, gist: gist,
      isRecovery: draft.gistID != nil && gist == nil)
    file.libraryRowID = rowID
    return file
  }

  private func request(forRow id: String) -> Opening.Request {
    let target = rowSelection(for: id)
    // A file that never reached GitHub only exists on this iPhone.
    if let draftID = target?.draftID,
      target?.gistID == nil
        || localDrafts.contains(where: { $0.id == draftID && $0.base == nil })
    {
      return .draft(id: draftID, rowID: id)
    }
    return .gist(id: target?.gistID ?? id, filename: target?.filename, rowID: id)
  }

  private func placeholder(for request: Opening.Request) -> Opening {
    let (rowID, title): (String, String?) =
      switch request {
      case .gist(let id, _, let rowID):
        (rowID ?? id, cachedLibrary?.gists.first { $0.id == id }?.displayName)
      case .draft(let id, let rowID):
        (rowID ?? id.uuidString, localDrafts.first { $0.id == id }?.description)
      case .today(let target, _): ("today/\(target.filename)", String(localized: "Today"))
      case .new: ("new", String(localized: "Untitled"))
      }
    return .init(
      request: request, rowID: rowID,
      title: state.gists.first { $0.id == rowID }?.title ?? title
        ?? String(localized: "Gist"))
  }

  func present(_ file: File) {
    var file = file
    file.libraryRowID = unfilteredRowID(for: file)
    opening = nil
    loadedFile = file
    state.selectedID = file.rowID
    if file.isRecovery { openError = Self.recoveryMessage }
    remember(file.selection)
    if let session = sessions.values.first(where: { $0.file.refersToSameFile(as: file) }) {
      session.adoptPresentation(file)
    } else {
      sessions[file.draft.id] = FileSession(file: file, library: self)
    }
  }

  func unfilteredRowID(for file: File) -> String? {
    state.gists.first {
      $0.id == file.draft.id.uuidString
        || ($0.gistID != nil && $0.gistID == file.selection.gistID
          && ($0.filename == nil || $0.filename == file.filename))
    }?.id
  }

  /// Opens a file in the detail column. A newer open supersedes this one, but keeps any file this
  /// one created.
  public func open(_ request: Opening.Request) async {
    guard let account, pendingAccount == nil else {
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
      present(opened)
    } catch is CancellationError {
      if token == fileRequest { state.selectedID = loadedFile?.rowID }
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

  func openRow(id: String) async {
    await open(request(forRow: id))
  }

  func file(
    for request: Opening.Request, account: Account
  ) async throws -> File {
    switch request {
    case .gist(let id, let filename, let rowID):
      if let cached = cachedFile(gistID: id, filename: filename, rowID: rowID) { return cached }
      let gist = try await sync.gist(id: id, accountID: account.id)
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
      guard let userID = account.githubUserID else { throw AccountError.reconnectGitHub }
      let text = try await sync.content(gist: gist, filename: selected, accountID: account.id)
      // The read is cached on this iPhone, so the note opens from here next time.
      try await reloadLocalState(accountID: account.id)
      var file = File(
        draft: try await sync.current(
          Draft(
            accountID: account.id, githubUserID: userID, gist: gist, filename: selected,
            text: text)),
        gist: gist)
      file.libraryRowID = rowID
      return file
    case .draft(let id, let rowID):
      if !localDrafts.contains(where: { $0.id == id }) {
        try await reloadLocalState(accountID: account.id)
      }
      guard let draft = localDrafts.first(where: { $0.id == id }) else { throw DraftError.notFound }
      return localFile(draft, rowID: rowID)
    case .today(let target, let focusesEditor):
      let daily = cachedLibrary?.owned.first(where: \.isDailyNote)
      let day = DailyNote(day: target, cache: cachedLibrary, drafts: localDrafts)
      var file: File
      if let draft = localDrafts.first(where: { $0.id == day.draftID }) {
        file = File(draft: draft, gist: daily)
      } else if let daily,
        let cached = cachedFile(gistID: daily.id, filename: target.filename)
      {
        file = cached
      } else {
        let today = try await sync.today(accountID: account.id, target: target)
        file = File(draft: today.draft, gist: today.gist)
      }
      file.editingRequestID = focusesEditor ? UUID() : nil
      file.revealsDetail = focusesEditor
      return file
    case .new:
      guard let userID = account.githubUserID else { throw AccountError.reconnectGitHub }
      var file = File(draft: Draft(accountID: account.id, githubUserID: userID))
      file.editingRequestID = UUID()
      return file
    }
  }

  /// Closes a new note you left without writing in it, since nothing of it was kept.
  func close(_ session: FileSession) {
    guard !session.draft.isSaved, session.draft.gistID == nil,
      state.selectedID == nil || visibleFile?.draft.id != session.draft.id
    else { return }
    sessions[session.draft.id] = nil
    if loadedFile?.draft.id == session.draft.id { loadedFile = nil }
  }

  public func showLibrary() {
    fileRequest = UUID()
    opening = nil
    state.selectedID = nil
  }

  func remember(_ selection: FileReference) {
    guard let account else { return }
    lastOpened.save(selection, accountID: account.id)
  }

  /// Reopens the file you last had open. With nothing remembered, nothing opens, because a file
  /// only starts when you ask for it.
  func restoreLastOpened() async {
    guard loadedFile == nil, state.selectedID == nil, opening == nil, let account,
      pendingAccount == nil
    else { return }
    let saved = lastOpened.selection(accountID: account.id)
    if let draftID = saved?.draftID, localDrafts.contains(where: { $0.id == draftID }) {
      await open(.draft(id: draftID))
    } else if let gistID = saved?.gistID {
      await open(.gist(id: gistID, filename: saved?.filename))
    }
  }

  private static let recoveryMessage = String(
    localized:
      "This gist was deleted on GitHub. Your unpublished text is kept on this iPhone.")
}

extension FileSession {
  public func requestCreationFocus() {
    guard let request = file.editingRequestID, request != lastEditingRequestID, canMutate
    else { return }
    lastEditingRequestID = request
    mode = .edit
    editor.requestFocusAtEnd()
  }

  func adoptPresentation(_ incoming: File) {
    guard incoming.accountID == draft.accountID,
      incoming.gist?.id == file.gist?.id, incoming.filename == draft.filename
    else { return }
    file.libraryRowID = incoming.libraryRowID
    file.editingRequestID = incoming.editingRequestID
    file.revealsDetail = incoming.revealsDetail
    if let gist = incoming.gist { file.gist = gist }
  }
}

public struct FileReference: Codable, Equatable, Sendable {
  let gistID: String?
  let filename: String
  let draftID: UUID?
}

@MainActor
public final class LastOpened {
  private let defaults: UserDefaults?
  private var memory: [UUID: FileReference] = [:]

  public init(defaults: UserDefaults? = nil) { self.defaults = defaults }

  /// The file to reopen at launch. One that can't be read is simply forgotten.
  func selection(accountID: UUID) -> FileReference? {
    guard let defaults else { return memory[accountID] }
    return defaults.data(forKey: key(accountID)).flatMap {
      try? JSONDecoder().decode(FileReference.self, from: $0)
    }
  }

  func save(_ selection: FileReference, accountID: UUID) {
    guard let defaults else {
      memory[accountID] = selection
      return
    }
    defaults.set(try? JSONEncoder().encode(selection), forKey: key(accountID))
  }

  func clear(accountID: UUID) {
    defaults?.removeObject(forKey: key(accountID))
    memory[accountID] = nil
  }

  /// Keeps its original name so the last-opened file survives the update.
  private func key(_ accountID: UUID) -> String {
    "notebook.selection.\(accountID.uuidString)"
  }
}
