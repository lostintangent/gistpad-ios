# Screens

The Library, the gist screen and their sheets, in SwiftUI for iOS 27.2. Screens
take Sendable values and closures. The app owns navigation, sign-in, the editor,
Preview and sync, and nothing here writes to GitHub. Visual rules live in
[design.md](../../docs/design.md).

## Library

`LibraryView` is the sidebar of a `NavigationSplitView` and a pushed list on a
compact screen. The split view's owner passes `isSidebar`, because a sidebar
column always reads as compact. Pinned comes first, then date groups from Today
to past years, then Daily Notes, Starred Gists and Archived Gists. Each is a
native `Section(isExpanded:)` with a quiet count, and empty sections never show.
Bind `expandedSections` and `isPinnedExpanded` to the account's preferences.

`LibraryState` is the observable model. Apply new gists with
`replace(gists:tags:dailyNoteCount:known:)` rather than making a new model, so
search, tag filters and selection survive. Pass `known: false` until the
account's gists are known, and counts stay absent rather than zero. Search
matches titles and tags like the web, tag filters combine with AND, and the open
gist stays listed. `GistItem.gistID` is the published gist, nil for a draft or
recovery copy.

`LibraryActions` carries the row actions. Every owned row can be deleted in any
state. A revealed Delete, from a swipe or Edit's minus, calls `delete` with the
row's ID at once, and the context menu's confirms first. The app decides what
that removes. The Library owns its search, so it stays in the
Library column through folds and rotations. Apply
`.libraryRail(isVisible:today:create:openToday:)` to regular detail content, so
New and Today sit beside the open gist. Pass the account's `GitHubStatus`
as `status`. A problem shows `GitHubStatusControl` in the bottom bar, or the
empty state explains it when there's nothing to list.

## Gist screen

`GistScreen` keeps the injected editor and Preview mounted and switches between
Edit, Split and Preview with `FileMode`. The app passes `allowsSplit` from the
width it has, and a read-only gist shows Preview only. The title leads the bar
in the same glass capsule in every note, with any file but README.md named under
it. In a gist it opens a menu: the files, when there are two or more, then
Rename File and Add File in your own gist, or just the files in someone else's.
A daily note's capsule holds its day, exactly as its row reads, with no filename
and no menu. The opening and failed screens show the same capsule with
`gistTitle(_:)` from the first frame. The title is never wider than
"🤖 Coding Agent Culture" in its own font, so it grows with Dynamic Type and a
longer one ends in "…" rather than moving Mode, Comments or More to the
overflow menu.

`GistActions` members that are nil hide their controls. Edits publish by
themselves, so there's no Publish button. A conflict or lost sign-in shows a
button that opens the diff or reconnects. Comments is a toggle with a quiet count
from `ToolbarBadgeLabel`. The More menu holds Pin, Star, Share and Copy Link,
then Rename, Tags, Intelligence and Find and Replace, then Archive and Delete.
Menu items never end in "…". A daily note is a file, not a gist, so the app
gives it no Pin, Star, Archive, Tags or Rename. It has no title menu, and its
Library row offers only Delete. Share hides while Comments is a
sheet in compact width, because the share sheet can't present over it. Delete
confirms with the title, the day for a daily note, before it calls `delete`.

## Sheets

`TagEditor(gistID:tags:selectedTagIDs:save:)` keeps every choice in the sheet
until Save, then sends the preference changes in order: upserts, memberships,
deletions.
A retry resends the same edits, and the sheet closes only after `save` succeeds.
`RenameSheet(_:save:)` renames the gist or a file, or adds a file, from a
`RenameTarget`, and also closes only after `save` succeeds.

`SettingsSheet` holds the account with Sign Out beneath it, the Writing
preferences and the app's `appearance` rows, and confirms each preference with
`savePreference`.
`AccentColorRow` saves the personal color, and Appearance's `.accent(savedHex:)` applies it
to content, never to navigation or commands.

## Validation

`swift test` covers Library sections, counts and filters, date groups, tag
contrast and the tag editor's edits. `GistPadUITests` drives these screens
through the Debug fixture launches in [the capture matrix](../../docs/capture-matrix.md),
and `scripts/capture-matrix.sh` captures them for Designer's review.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScreensTests
```
