# GistPadPlatform

Widgets, controls, Shortcuts and Spotlight open the app with `gistpad://` links
for Today, Add to Today, a gist's file and a local draft. `NotebookRoute` reads
and writes them, and the app opens them through its ordinary navigation.
Receiving a link never publishes. The sign-in callback stays with Auth.

gistpad.dev links open in the browser. The app doesn't claim them, because that
needs the web's `apple-app-site-association` file deployed first.

## System surfaces

`NoteEntity` is an `IndexedEntity` with title, exact filename, tags and a cached
snippet, indexed with complete file protection. `NoteEntityQuery` resolves
identifiers and strings for the signed-in account and answers the system's
reindex requests.

Open Note, Open Today and Add to Today are App Shortcuts. The Add to Today control
opens the capture sheet, and shortcut-provided text skips it. Captures append
through `TodayAppend` and the same `SharedDraftCommand` path as the editor, then
leave publishing to the editor's autosave.

Both targets read `SharedNotebookStore`, one JSON snapshot in the
`group.dev.gistpad.GistPad` container. It holds the active account, cached note
metadata and Today's tasks, written atomically with protection until first
unlock so Lock Screen and StandBy can read it. No drafts or credentials are
shared.

Task and capture intents run in the main app (`allowedExecutionTargets = .main`),
which resolves them through `AppDependencyManager`. A widget toggle checks the
account, file, generation and exact task marker, and reaches an open editor as
one Undo step. A checked task means the edit is saved on the phone. Publishing
follows the app's usual autosave and leave-app paths.

The Today widget supports small, medium, the Lock Screen accessory families and
StandBy. Timelines never create a note. Before first unlock it shows an
invitation instead of tasks.

## Validation

`swift test` covers link round-trips and the snapshot's task and append commands
with in-memory stores. `NotebookPlatformTests` in the app host covers a widget
toggle reaching the open editor and Add to Today from a Shortcut. Installed
widgets, Control Center, Spotlight launches and provisioning are checked on device.
