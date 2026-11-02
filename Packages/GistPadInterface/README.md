# GistPadInterface

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
state. The Library confirms first, then calls `delete` with the row's ID, and the
app decides what that removes. Apply `.librarySearch(state:)` to the split root
and `.libraryRail(isVisible:today:create:openToday:)` to regular detail content,
so New and Today sit beside the open gist. Pass a `GitHubStatusProblem` as
`problem` to show `GitHubStatusControl` in the bottom bar.

## Gist screen

`GistScreen` keeps the injected editor and Preview mounted and switches between
Edit, Split and Preview with `FileMode`. The app passes `allowsSplit` from the
width it has, and a read-only gist shows Preview only. With more than one file,
the title menu switches files and the subtitle names any file but README.md.

`GistActions` members that are nil hide their controls. Publish shows when
autosave is off or a publish that can be retried didn't land, as
`PublishState.showsPublish` decides. A conflict or lost sign-in shows a button
that opens the diff or reconnects. Comments is a toggle with a quiet count from
`ToolbarBadgeLabel`. The More menu holds Pin, Star, Share and Copy Link, then
Rename, Tags, Files, Intelligence and Find and Replace, then Open in GitHub,
Archive and Delete. Share hides while Comments is a sheet in compact width,
because the share sheet can't present over it. Delete confirms with the gist's
title, or the day for a daily note, before it calls `delete`.

## Sheets

`TagEditor(tags:selectedTagIDs:save:)` keeps every choice in the sheet until
Save, then sends `TagEdit` operations in order: upserts, memberships, deletions.
A retry resends the same edits, and the sheet closes only after `save` succeeds.
`AccentColorRow` saves the personal color, and `.accent(savedHex:)` applies it
to content, never to navigation or commands. `CommentsConversation` and
`CommentsComposer` show a gist's threads and the composer, while the app owns
the conversation from GistPadComments.

## Validation

`swift test` covers Library sections, counts and filters, date groups, tag
contrast and the tag editor's edits. `GistPadUITests` drives these screens
through the Debug fixture launches in [the capture matrix](../../docs/capture-matrix.md),
and `scripts/capture-matrix.sh` captures them for Designer's review.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadInterface
```
