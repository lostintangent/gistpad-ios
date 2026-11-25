# Model

`GistPadModel` does what you ask with the things the [Store](../../Shared/Store/README.md)
keeps: sign in, list your gists, open, save, publish, refresh, star, archive,
rename and delete. It's the app's one `@Observable` model, on the main actor, and
every screen, intent and control reads it. It's the only code that talks to
`GitHubClient`, the `GistCache` and the `GistFileDraftStore`, and `serially`
sends GitHub and the drafts one write at a time. [docs/sync.md](../../../docs/sync.md)
is the promise to the user, and this module keeps it.

```text
GistPadModel
  account: GistPadAccount?        who's signed in
  phase                           loading, signing in, refreshing, signing out, ready
  refreshFailure: Failure?        why the list couldn't read GitHub
  failure: Failure?               the one the app shows in an alert, titled with what didn't happen
  state: LibraryState             the list, built from the cache and drafts
  editors: [UUID: GistFileEditor] every file opened since launch
  opening: Opening?               the file on its way to the detail column
  activeEditor: GistFileEditor?   the file in the detail column, once nothing is opening

GistFile                          a file as it is on this iPhone
  gist  filename  draft?  published?  text  nextDraft

GistFileEditor                    a file you've opened
  file: GistFile  editor: MarkdownEditor  mode  status

CommentsModel                     a gist's conversation
  comments?  threads  target  draft  refreshFailure: Failure?  failure: (request, reason)?
```

## Three kinds of file

- `Gist.File` is GitHub's JSON for one file, from the Store.
- `GistFile` is a file as it is on this iPhone: its gist, its filename, and
  your `draft` once you've typed in it, otherwise GitHub's `published` text. A
  new gist or day carries its draft in memory until there's something in it.
  `id` is fixed when the file opens, so a rename or a new gist's first publish
  keeps its editor. `nextDraft` is the draft your next keystroke saves.
- `GistFileEditor` wraps the `MarkdownEditor` with the gist part: saving each
  keystroke, autosave, publishing, preview or edit mode, and `status`. The model
  keeps one per file opened since launch, so returning to a file keeps your
  place and your undo.

## One file per scenario

| File | What it does |
|---|---|
| `Accounts.swift` | `start`, `signIn` and `reconnect`, and images for the account. Signing in as someone else saves your open files and signs you out first. |
| `Comments.swift` | `comments(for:)`, a gist's `CommentsModel` as the signed-in account, with one in-memory draft. Editing a comment borrows the composer and gives back the unsent draft, and posting an edit is a post. A failed load sets `refreshFailure`. A failed post or delete sets `failure` with its request and keeps the draft, and `retry()` sends it again. |
| `Opening.swift` | `open(rowID:)` and `open(_:)`, the file in the detail column, and the last opened file. |
| `Saving.swift` | Each keystroke saved on this iPhone, and `apply` for edits from outside the editor. |
| `Publishing.swift` | Autosave, `publish`, `returnToApp` and `leaveApp`. |
| `Refreshing.swift` | `refresh`, for the list and for the open file. |
| `Conflicts.swift` | `resolveConflict`. |
| `DailyNotes.swift` | `today`, and moving Today to a new day. |
| `Changes.swift` | Changes that apply right away: preferences, star, archive, rename, add a file, delete and sign out. |

## Publishing

Publishing and Today keep [docs/sync.md](../../../docs/sync.md)'s rules. Beyond
them, a create that was cut off is found by its description and the sent bytes,
so a gist is never created twice, and autosave runs only in the foreground. A
failed publish keeps its `Failure` until you type, publish again or reconnect,
and the next moment retries it only when it offers `.tryAgain`. GitHub has no
conditional write, so the fresh read before a publish narrows a race with the
web but can't close it.

## Testing

`ModelFixture` builds a model against a `FixtureServer` and an in-memory draft
store, so tests run the real verbs without GitHub.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ModelTests
```
