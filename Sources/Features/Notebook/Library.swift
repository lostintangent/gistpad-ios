import Foundation
import Interface
import OSLog
import Observation
import Sync

@MainActor @Observable
public final class Library {
  public let state = LibraryState()
  public internal(set) var account: Account?
  public internal(set) var pendingAccount: Account?
  var loadedFile: File?
  public internal(set) var isSigningIn = false
  public internal(set) var isSigningOut = false
  /// Launch is restoring the account and this iPhone's drafts. Links wait for it, not for GitHub.
  public internal(set) var isStarting = false
  /// The file opening in the detail column, until it's presented or fails.
  public internal(set) var opening: Opening?
  public internal(set) var localDrafts: [Draft] = []
  /// Counts drafts recorded in memory, so a local read that started earlier knows it's stale.
  var localDraftRecords = 0
  public internal(set) var cachedLibrary: CachedLibrary?
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
  public internal(set) var sessions: [UUID: FileSession] = [:]
  /// Autosave runs only while the app is in the foreground.
  public var isForeground = false
  var isApplying = false

  @ObservationIgnored let sync: GitHubSync
  @ObservationIgnored let lastOpened: LastOpened
  @ObservationIgnored var libraryRequest = UUID()
  @ObservationIgnored var refreshedAt: Date?
  @ObservationIgnored var fileRequest = UUID()
  @ObservationIgnored let logger = Logger(
    subsystem: "dev.gistpad.GistPad", category: "Library")

  public init(
    sync: GitHubSync, lastOpened: LastOpened = LastOpened()
  ) {
    self.sync = sync
    self.lastOpened = lastOpened
  }

  public func gistID(forRow rowID: String) -> String? {
    if cachedLibrary?.gists.contains(where: { $0.id == rowID }) == true { return rowID }
    return state.gists.first { $0.id == rowID && $0.isDailyNote }?.gistID
  }

  func updateLibraryExcerpt(for draft: Draft) {
    let gist = cachedLibrary?.gists.first { $0.id == draft.gistID }
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

  public func reloadPlatformState(accountID: UUID) async throws {
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
    try await reloadLocalState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { throw AccountError.accountChanged }
  }

  func reloadLocalState(accountID: UUID) async throws {
    let records = localDraftRecords
    let local = try await sync.localState(accountID: accountID)
    guard account?.id == accountID, pendingAccount == nil else { return }
    // A draft saved while this read ran is newer than the read, so read again.
    if localDraftRecords != records { return try await reloadLocalState(accountID: accountID) }
    let drafts = local.drafts
    localDrafts = drafts
    cachedLibrary = local.cache
    projectLibrary()
    updateToday()
  }

  func projectLibrary() {
    guard let account else { return }
    let contents = Self.libraryContents(
      owned: cachedLibrary?.owned ?? [], starred: cachedLibrary?.starred ?? [],
      account: account, drafts: localDrafts, cached: cachedLibrary)
    state.replace(
      gists: contents.gists, tags: contents.tags, dailyNoteCount: contents.dailyNoteCount,
      known: cachedLibrary != nil)
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
      var cache = cachedLibrary, cache.gists.first(where: { $0.id == gistID })?.isDailyNote == false
    else { return }
    let update: (Gist) -> Gist = { $0.id == gistID ? $0.withCommentCount(total) : $0 }
    cache.owned = cache.owned.map(update)
    cache.starred = cache.starred.map(update)
    cache.details = cache.details.mapValues(update)
    cachedLibrary = cache
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
  public func details(for file: File) -> GistDetails {
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
      isStarred: cachedLibrary?.starred.contains(where: { $0.id == gist.id }) ?? false,
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
    owned: [Gist], starred: [Gist], account: Account, drafts: [Draft] = [],
    cached: CachedLibrary? = nil
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
          title: day.map { GistFile.displayName($0.filename) } ?? gist.displayName,
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
          }.map(GistFile.decodeContent)
          updateLibraryContent(
            &item,
            text: gistDrafts.first { $0.filename == filename }?.text
              ?? cached?.content(gist: gist, filename: filename) ?? inline)
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
        title: daily ? GistFile.displayName(draft.filename)
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
