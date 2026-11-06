import Foundation
import Screens
import OSLog
import Observation
import Store

@MainActor @Observable
public final class GistPadModel {
  public let state = LibraryState()
  public internal(set) var account: GistPadAccount?
  public internal(set) var pendingAccount: GistPadAccount?
  var loadedFile: GistFile?
  public internal(set) var isSigningIn = false
  public internal(set) var isSigningOut = false
  /// Launch is restoring the account and this iPhone's drafts. Links wait for it, not for GitHub.
  public internal(set) var isStarting = false
  /// The file opening in the detail column, until it's presented or fails.
  public internal(set) var opening: Opening?
  public internal(set) var localDrafts: [Draft] = []
  /// Counts drafts recorded in memory, so a local read that started earlier knows it's stale.
  var localDraftRecords = 0
  public internal(set) var gistCache: GistCache?
  var isCreating = false
  /// The one message the app shows in an alert, such as a failed open or change.
  public var openError: String?
  public var isShowingError: Bool {
    get { openError != nil }
    set { if !newValue { openError = nil } }
  }
  public internal(set) var remoteRefreshProblem: RemoteReadProblem?
  var isRefreshingRemote = false
  /// The files opened this session, by draft. Returning to one keeps its caret, scroll and undo.
  public internal(set) var editors: [UUID: GistFileEditor] = [:]
  /// Autosave runs only while the app is in the foreground.
  public var isForeground = false
  var isApplying = false

  @ObservationIgnored let accountStore: GistPadAccountStore
  @ObservationIgnored let draftStore: GistFileDraftStore
  @ObservationIgnored let lastOpened: LastOpened
  @ObservationIgnored private var clients: [UUID: GitHubClient] = [:]
  @ObservationIgnored private var isWriting = false
  @ObservationIgnored private var writers: [CheckedContinuation<Void, Never>] = []
  @ObservationIgnored var libraryRequest = UUID()
  @ObservationIgnored var refreshedAt: Date?
  @ObservationIgnored var fileRequest = UUID()
  @ObservationIgnored let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Library")

  public init(accounts: GistPadAccountStore, drafts: GistFileDraftStore, lastOpened: LastOpened = LastOpened()) {
    accountStore = accounts
    draftStore = drafts
    self.lastOpened = lastOpened
  }

  /// GitHub as the account sees it, one client per account.
  func client(accountID: UUID) async -> GitHubClient {
    if let client = clients[accountID] { return client }
    let client = await accountStore.githubClient(accountID: accountID)
    if let existing = clients[accountID] { return existing }
    clients[accountID] = client
    return client
  }

  /// A gist as GitHub has it now, which the cache then keeps.
  func gist(id: String, accountID: UUID) async throws -> Gist {
    let gist = try await client(accountID: accountID).gist(id: id)
    try updateCache(accountID) { $0.update(gist) }
    return gist
  }

  /// A file's text from the cache when it's current, otherwise from GitHub, which then caches it.
  /// Nil when the gist has no such file.
  public func text(of filename: String, in gist: Gist, accountID: UUID) async throws -> String? {
    guard gist.files[filename] != nil else { return nil }
    if let cached = try cache(accountID)?.currentText(of: filename, in: gist) { return cached }
    // GitHub lists a gist without its revision, so read the gist to know which text this is.
    let read = gist.revision == nil ? try await self.gist(id: gist.id, accountID: accountID) : gist
    let text = try await client(accountID: accountID).content(gist: read, filename: filename)
    try updateCache(accountID) { $0.store(text, of: filename, in: read) }
    return text
  }

  /// The account's cache: the one in memory for the signed-in account, otherwise as saved.
  func cache(_ accountID: UUID) throws -> GistCache? {
    if let gistCache, gistCache.accountID == accountID { return gistCache }
    return try GistCache.load(accountID: accountID, from: draftStore.modelContainer)
  }

  /// Changes the account's cache and saves it, once the account has one.
  func updateCache(_ accountID: UUID, _ change: (inout GistCache) -> Void) throws {
    guard var cache = try cache(accountID) else { return }
    change(&cache)
    try save(cache)
  }

  /// Keeps GitHub's copy of a file, which is never wrong to cache.
  func cache(_ remote: RemoteFile, filename: String, accountID: UUID) throws {
    try updateCache(accountID) { cache in
      cache.update(remote.gist)
      if let content = remote.content { cache.store(content, of: filename, in: remote.gist) }
    }
  }

  func save(_ cache: GistCache) throws {
    try cache.save(to: draftStore.modelContainer)
    if account?.id == cache.accountID { gistCache = cache }
  }

  /// Runs one write to GitHub or the drafts at a time, so a publish, a new day and a rename never
  /// interleave.
  func serially<Value>(_ write: () async throws -> Value) async throws -> Value {
    if isWriting {
      await withCheckedContinuation { writers.append($0) }
    } else {
      isWriting = true
    }
    defer {
      if writers.isEmpty { isWriting = false } else { writers.removeFirst().resume() }
    }
    try Task.checkCancellation()
    return try await write()
  }

  public func gistID(forRow rowID: String) -> String? {
    if gistCache?.gists.contains(where: { $0.id == rowID }) == true { return rowID }
    return state.gists.first { $0.id == rowID && $0.isDailyNote }?.gistID
  }

  func updateLibraryExcerpt(for draft: Draft) {
    let gist = gistCache?.gists.first { $0.id == draft.gistID }
    let isDaily = gist?.isDailyNote == true
      || draft.description == DailyNote.gistDescription
    if isDaily, DailyNote.date(filename: draft.filename) == nil { return }
    if let gist, !gist.isDailyNote, draft.filename != gist.defaultMarkdownFilename { return }
    let rowID =
      if let gist, gist.isDailyNote, owns(gist) {
        "\(gist.id)/\(draft.filename)"
      } else { gist?.id ?? draft.id.uuidString }
    guard let index = state.gists.firstIndex(where: { $0.id == rowID }) else {
      projectLibrary()
      return
    }
    if state.gists[index].gistID == nil {
      state.gists[index].updatedAt = draft.updatedAt
    }
    Self.updateLibraryContent(&state.gists[index], text: draft.text)
  }

  private static func updateLibraryContent(_ item: inout GistItem, text: String?) {
    if item.isDailyNote {
      item.progress = text.map(TaskProgress.init(markdown:))
      item.isOverdue = item.dailyDate.map {
        $0 < Calendar.current.startOfDay(for: .now) && (item.progress?.remaining ?? 0) > 0
      } ?? false
    }
  }

  func reloadLocalState(accountID: UUID) async throws {
    let records = localDraftRecords
    let drafts = try await draftStore.drafts(accountID: accountID)
    let cache = try cache(accountID)
    guard account?.id == accountID, pendingAccount == nil else { return }
    // A draft saved while this read ran is newer than the read, so read again.
    if localDraftRecords != records { return try await reloadLocalState(accountID: accountID) }
    localDrafts = drafts
    gistCache = cache
    projectLibrary()
    updateToday()
  }

  func projectLibrary() {
    guard let account else { return }
    let contents = Self.libraryContents(
      owned: gistCache?.owned ?? [], starred: gistCache?.starred ?? [],
      account: account, drafts: localDrafts, cached: gistCache)
    state.replace(
      gists: contents.gists, tags: contents.tags, dailyNoteCount: contents.dailyNoteCount,
      known: gistCache != nil)
    // A note opened before GitHub's list arrives sits under its draft's row until the gist's row
    // replaces it, so keep it selected under the new row.
    guard let file = loadedFile, !state.gists.contains(where: { $0.id == file.rowID }),
      let rowID = unfilteredRowID(for: file)
    else { return }
    let wasSelected = state.selectedID == file.rowID
    loadedFile?.libraryRowID = rowID
    if wasSelected, opening == nil { state.selectedID = rowID }
  }

  /// The Markdown files a gist shows, with any this iPhone has that GitHub doesn't yet.
  private static func filenames(of gist: Gist, drafts: [Draft]) -> [String] {
    Set(gist.markdownFilenames + drafts.filter { $0.gistID == gist.id }.map(\.filename)).sorted()
  }

  /// Keeps a gist's comment count current in the library once its conversation loads.
  public func recordCommentCount(accountID: UUID, gistID: String, total: Int) {
    guard account?.id == accountID, pendingAccount == nil, !isSigningOut,
      var cache = gistCache, cache.gists.first(where: { $0.id == gistID })?.isDailyNote == false
    else { return }
    cache.setCommentCount(total, gistID: gistID)
    gistCache = cache
    projectLibrary()
  }

  /// A gist belongs to the signed-in account when its owner is the account's GitHub user, which
  /// holds across login renames.
  func owns(_ gist: Gist) -> Bool {
    guard let id = account?.githubUserID else { return false }
    return gist.owner?.id == id
  }

  /// A file's header and actions, read from its gist, the account's preferences and the drafts on
  /// this iPhone, so it's always current.
  public func details(for file: GistFile) -> GistDetails {
    let title =
      file.gist?.displayName
      ?? (file.draft.description.isEmpty ? nil : file.draft.description)
      ?? String(localized: "Untitled")
    guard let gist = file.gist, let account, account.id == file.accountID else {
      return GistDetails(
        title: title, files: [.init(id: file.filename, filename: file.filename)],
        selectedFileID: file.filename,
        isDailyNote: file.gist?.isDailyNote ?? (file.draft.description == DailyNote.gistDescription),
        isAutoSaveEnabled: account?.id == file.accountID
          && account?.preferences.isAutoSaveEnabled == true)
    }
    let files = Self.filenames(of: gist, drafts: localDrafts)
    return GistDetails(
      title: title,
      files: files.map { .init(id: $0, filename: $0) }, selectedFileID: file.filename,
      access: owns(gist) ? .editable : .readOnly,
      isPinned: account.preferences.pinnedGists.contains(gist.id),
      isStarred: gistCache?.starred.contains(where: { $0.id == gist.id }) ?? false,
      isArchived: gist.isArchived, isDailyNote: gist.isDailyNote,
      tags: state.tags.filter {
        account.preferences.gistTags[gist.id]?.contains($0.id) == true
      },
      isAutoSaveEnabled: account.preferences.isAutoSaveEnabled,
      commentCount: gist.isDailyNote ? nil : gist.commentCount,
      shareURL: file.isRecovery || gist.files[file.filename] == nil
        ? nil : try? GistLinks(gist: gist, filename: file.filename).shareURL)
  }

  static func libraryContents(
    owned: [Gist], starred: [Gist], account: GistPadAccount, drafts: [Draft] = [],
    cached: GistCache? = nil
  )
    -> (gists: [GistItem], tags: [Tag], dailyNoteCount: Int?)
  {
    let ownedIDs = Set(owned.map(\.id))
    let starredIDs = Set(starred.map(\.id))
    var unique: [String: Gist] = [:]
    for gist in owned + starred {
      if let existing = unique[gist.id], existing.updatedAt > gist.updatedAt { continue }
      unique[gist.id] = gist
    }
    let preferences = account.preferences
    var items = unique.values.flatMap { gist -> [GistItem] in
      let gistDrafts = drafts.filter { $0.gistID == gist.id }
      let fileCount = filenames(of: gist, drafts: gistDrafts).count
      let days: [(filename: String, date: Date)?]
      if gist.isDailyNote, ownedIDs.contains(gist.id) {
        days = Set(gist.files.keys).union(gistDrafts.map(\.filename)).compactMap { filename in
          DailyNote.date(filename: filename).map { (filename: filename, date: $0) }
        }.map(Optional.some)
      } else {
        days = [nil]
      }
      return days.map { day in
        var item = GistItem(
          id: day.map { "\(gist.id)/\($0.filename)" } ?? gist.id,
          title: day.map { Gist.File.displayName($0.filename) } ?? gist.displayName,
          updatedAt: gist.updatedAt, gistID: gist.id,
          owner: gist.owner?.login, isOwned: ownedIDs.contains(gist.id),
          isSecret: !gist.isPublic, isPinned: preferences.pinnedGists.contains(gist.id),
          isStarred: starredIDs.contains(gist.id), isArchived: gist.isArchived,
          isDailyNote: gist.isDailyNote, tagIDs: Set(preferences.gistTags[gist.id] ?? []),
          filename: day?.filename,
          dailyDate: day?.date,
          fileCount: fileCount,
          commentCount: gist.isDailyNote ? nil : gist.commentCount
        )
        // Only daily rows read file content, for their task progress.
        if gist.isDailyNote {
          let filename = day?.filename ?? DailyNote.filename()
          let inline = gist.files[filename].flatMap {
            $0.truncated == true ? nil : $0.content
          }.map(Gist.File.decodeContent)
          updateLibraryContent(
            &item,
            text: gistDrafts.first { $0.filename == filename }?.text
              ?? cached?.text(of: filename, in: gist) ?? inline)
        }
        return item
      }
    }
    items += drafts.filter { $0.gistID.map { unique[$0] == nil } ?? true }.compactMap { draft in
      let daily = draft.description == DailyNote.gistDescription
      let day = daily ? DailyNote.date(filename: draft.filename) : nil
      if daily, day == nil { return nil }
      var item = GistItem(
        id: draft.id.uuidString,
        title: daily ? Gist.File.displayName(draft.filename)
          : (draft.description.isEmpty ? String(localized: "Untitled") : draft.description),
        updatedAt: draft.updatedAt, isRecovery: draft.gistID != nil,
        isSecret: true, isDailyNote: daily, filename: draft.filename,
        dailyDate: day)
      updateLibraryContent(&item, text: draft.text)
      return item
    }
    let hasIncompleteDaily = unique.values.contains {
      ownedIDs.contains($0.id) && $0.isDailyNote && $0.truncated == true
    }
    return (
      gists: items.sorted {
        if $0.updatedAt != $1.updatedAt {
          return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        return $0.id < $1.id
      },
      tags: preferences.tags.map { tag in
        Tag(id: tag.id, name: tag.name, colorHex: tag.colorHex)
      }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
      dailyNoteCount: hasIncompleteDaily ? nil : items.filter {
        $0.isDailyNote && $0.isOwned && $0.dailyDate != nil
      }.count
    )
  }

  func report(_ error: any Error, operation: String) {
    logger.error(
      "Library \(operation, privacy: .public) failed: \(String(reflecting: type(of: error)), privacy: .public)"
    )
  }
}
