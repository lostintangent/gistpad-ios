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
    _ = try? await sync.content(gist: daily, filename: filename, accountID: accountID)
  }

  func updateToday() {
    state.today = DailyNote(cache: gistCache, drafts: localDrafts)
  }
}
