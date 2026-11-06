import Foundation
import Store

// Today follows the calendar, and the Today button counts the tasks of a day started anywhere.

extension GistPadModel {
  /// A new day moves Today and makes yesterday's unfinished tasks overdue.
  public func updateCalendar() {
    projectLibrary()
    updateToday()
  }

  /// GitHub lists gists without their text, so a refresh reads today's file whenever the Daily
  /// notes gist changed it. The Today button and today's row then count the tasks of a day started
  /// on the web. A failed read leaves what the phone had.
  func refreshToday(in owned: [Gist], accountID: UUID) async {
    let filename = DailyNote.filename()
    guard let daily = owned.first(where: \.isDailyNote), daily.files[filename] != nil,
      gistCache?.currentContent(gist: daily, filename: filename) == nil
    else { return }
    _ = try? await text(of: filename, in: daily, accountID: accountID)
  }

  /// Today's file, ready to edit: your draft once you've started the day, else the day as the daily
  /// notes gist has it or starts it, else the first day of a new daily notes gist. Typing saves it,
  /// and autosave publishes it like any other file.
  public func today(_ target: DailyNote.Day = .init()) async throws -> GistFile {
    guard let account, pendingAccount == nil else { throw AccountError.accountChanged }
    guard let userID = account.githubUserID else { throw AccountError.reconnectGitHub }
    let github = await client(accountID: account.id)
    return try await serially {
      let drafts = try await draftStore.drafts(accountID: account.id)
      let cached = try await draftStore.gistCache(accountID: account.id)
      // A day you've started opens from this iPhone, and opening it checks GitHub like any note.
      let day = DailyNote(day: target, cache: cached, drafts: drafts)
      if let started = drafts.first(where: { $0.id == day.draftID }) {
        return GistFile(draft: started, gist: cached?.owned.first { $0.id == started.gistID })
      }
      guard let gist = try await dailyGist(cached: cached, on: github) else {
        return GistFile(
          draft: Draft(
            accountID: account.id, githubUserID: userID, filename: target.filename,
            description: DailyNote.gistDescription,
            text: DailyNote.content(template: nil, filename: target.filename)))
      }
      guard gist.owner?.id == userID else { throw DraftError.readOnly }
      if let text = try await text(of: target.filename, in: gist, accountID: account.id) {
        return GistFile(
          draft: Draft(
            accountID: account.id, githubUserID: userID, gist: gist, filename: target.filename,
            text: text),
          gist: gist)
      }
      let template = try await text(of: DailyNote.templateFilename, in: gist, accountID: account.id)
      return GistFile(
        draft: Draft(
          accountID: account.id, githubUserID: userID, gistID: gist.id, filename: target.filename,
          description: gist.description ?? "",
          text: DailyNote.content(template: template, filename: target.filename),
          baseRevision: gist.revision),
        gist: gist)
    }
  }

  /// The daily gist as GitHub has it now, because the web may have started today since the
  /// library was cached. Offline, the library on this iPhone decides.
  private func dailyGist(cached: GistCache?, on github: GitHubClient) async throws -> Gist? {
    let daily = cached?.owned.first(where: \.isDailyNote)
    do {
      if let daily {
        do { return try await github.gist(id: daily.id) }
        // Deleting its last day on the web deleted it, so look for the one today joins.
        catch GitHubClientError.http(status: 404) {}
      }
      return try await github.listGists().first(where: \.isDailyNote)
    } catch let error as URLError where cached != nil && error.code != .cancelled {
      return daily
    }
  }

  func updateToday() {
    state.today = DailyNote(cache: gistCache, drafts: localDrafts)
  }
}
