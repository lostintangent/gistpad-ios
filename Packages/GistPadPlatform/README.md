# GistPadPlatform

Widgets, controls, Shortcuts and Spotlight open the app with `gistpad://` links
for Today, Add to Today, a gist's file and a local draft. `NotebookRoute` reads
and writes them, and the app opens them through its ordinary navigation.
Receiving a link never publishes. The sign-in callback stays with Auth.

gistpad.dev links open in the browser. The app doesn't claim them, because that
needs the web's `apple-app-site-association` file deployed first.

## System surfaces

`GistEntity` is an `IndexedEntity`, one per gist, with its title, tags and a
snippet, indexed with complete file protection. Opening one opens the gist the
way the Library does. `GistEntityQuery` resolves identifiers and strings for the
signed-in account and answers the system's reindex requests.

Open Note, Open Today and Add to Today are App Shortcuts. The Add to Today control
opens the capture sheet, and shortcut-provided text skips it. Captures start
today the way the app does, append Sync's `addToToday` edit through the same
`SharedDraftCommand` path as the editor, then leave publishing to autosave.

Both targets read `SharedNotebookStore`, one JSON snapshot in the
`group.dev.gistpad.GistPad` container. It holds the active account, one entity
per gist and today's `DailyNote`, your draft of the day or else GitHub's cached
copy. It's written atomically with protection until first unlock so Lock Screen
and StandBy can read it. No credentials are shared.

Task and capture intents run in the main app (`allowedExecutionTargets = .main`),
which resolves them through `AppDependencyManager`. A widget toggle starts
today, checks that the tapped task is still in place in your latest text, and
reaches an open editor as one Undo step. A checked task means the edit is saved
on the phone. Publishing follows the app's usual autosave and leave-app paths.

The Today widget comes in small, medium, and the inline and rectangular Lock
Screen families, and small works in StandBy. Timelines never create a note.
When the snapshot can't be read, such as before first unlock, it asks you to
open GistPad.

## Validation

`swift test` covers link round-trips and the widget snapshot preferring your
unpublished edits. `NotebookPlatformTests` in the app host covers a widget
toggle reaching the open editor and Add to Today from a Shortcut. Installed
widgets, Control Center, Spotlight launches and provisioning are checked on device.
