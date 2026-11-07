# Model

`GistPadModel` does what you ask with the things the [Store](../../Shared/Store/README.md)
keeps: sign in, list your gists, open, save, publish, refresh, star, archive,
rename and delete. It's the app's one `@MainActor` `@Observable` model, and every
screen, intent and control reads it. It's the only code that talks to
`GitHubClient`, the `GistCache` and the `GistFileDraftStore`, and `serially`
sends GitHub and the drafts one write at a time. [docs/sync.md](../../../docs/sync.md)
is the promise to the user, and this module keeps it.

```text
GistPadModel
  account: GistPadAccount?        who's signed in
  phase                           loading, signing in, refreshing, switching, ready
  problem: GitHubProblem?         why the list couldn't read GitHub
  state: LibraryState             the list, built from the cache and drafts
  editors: [UUID: GistFileEditor] every file opened since launch
  opening: Opening?               the file on its way to the detail column

GistFile                          a file as it is on this iPhone
  gist  filename  draft?  published?  text  nextDraft

GistFileEditor                    a file you've opened
  file: GistFile  editor: Editor  mode  status
```

## Three kinds of file

- `Gist.File` is GitHub's JSON for one file, from the Store.
- `GistFile` is a file as it is on this iPhone: its gist, its filename, and
  your `draft` once you've typed in it, otherwise GitHub's `published` text. A
  new gist or day carries its draft in memory until there's something in it.
  `id` is fixed when the file opens, so a rename or a new gist's first publish
  keeps its editor. `nextDraft` is the draft your next keystroke saves.
- `GistFileEditor` wraps the Markdown `Editor` with the gist part: saving each
  keystroke, autosave, publishing, preview or edit mode, and `status`. The model
  keeps one per file opened since launch, so returning to a file keeps your
  place and your undo.

## One file per scenario

| File | What it does |
|---|---|
| `Accounts.swift` | `start`, `signIn`, `switchAccount`, `keepCurrentAccount`, images and comments for the account. |
| `Opening.swift` | `open(rowID:)` and `open(_:)`, the file in the detail column, and the last opened file. |
| `Saving.swift` | Each keystroke saved on this iPhone, and `apply` for edits from outside the editor. |
| `Publishing.swift` | Autosave, `publish`, `returnToApp` and `leaveApp`. |
| `Refreshing.swift` | `refresh` for the list and `inspectRemoteChanges` for the open file. |
| `Conflicts.swift` | `resolveConflict`. |
| `DailyNotes.swift` | `today`, and moving Today to a new day. |
| `Changes.swift` | Changes that apply right away: preferences, star, archive, rename, add a file, delete and sign out. |

## Publishing

A publish reads GitHub's copy first. If GitHub has the base, the sent text or
already your text, your text is recorded as `sent` and then sent. When GitHub
confirms it, it becomes the base and the store lets the draft go unless you
typed since. Anything else on GitHub is a conflict. A create that was cut off is
found by its description and the sent bytes, so a gist is never created twice.
A new day joins the Daily notes gist GitHub has, and creates one only when
there's none.

Autosave publishes five seconds after typing stops, while the app is in the
foreground. Leaving a file and `leaveApp` publish too. `returnToApp` publishes
what's waiting, refreshes a stale list, moves Today to a new day and checks the
open file. A failure is the editor's `GitHubProblem` until you type, publish
again or reconnect. GitHub has no conditional write, so the fresh read narrows
a race with the web but can't close it.

## Daily notes

`today()` returns today's file, ready to edit: your draft if you've started the
day, without asking GitHub. Otherwise it reads the daily gist from GitHub,
because the web may have started today since the cache was written. Then it's
the web's file for today, else a new file from `template.md` with `{{date}}`
filled in, else the first day of a new daily gist with a `# YYYY-MM-DD` heading.
Offline, the cache's answer stands. Nothing is stored until you type.

## Testing

`ModelFixture` builds a model against a `FixtureServer` and an in-memory draft
store, so tests run the real verbs without GitHub.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ModelTests
```
