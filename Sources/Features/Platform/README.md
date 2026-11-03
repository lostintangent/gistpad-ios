# Platform

Widgets, controls, Shortcuts and Spotlight open the app with `gistpad://` links
for Today, Add to Today, a new gist, a gist's file and a gist that's only on the phone.
`GistPadLink` reads and writes them, and `PendingLink` hands one to the app,
which opens it through its ordinary navigation.
Receiving a link never publishes. The sign-in callback stays with Auth.

gistpad.dev links open in the browser. The app doesn't claim them, because that
needs the web's `apple-app-site-association` file deployed first.

## System surfaces

`GistEntity` is an `IndexedEntity`, one per gist, with its title, tags and a
snippet, indexed with complete file protection. Opening one opens the gist the
way the Library does. `GistEntityQuery` resolves identifiers and strings for the
signed-in account and answers the system's reindex requests. The app updates the
index in the background after each snapshot, so nothing waits on Spotlight, and
deletes just the gists that went away since the last one, including while the
app wasn't running.

Open Gist, Open Today, Add to Today and New Gist are App Shortcuts. Add to Today,
Open Today and New Gist are also controls. The Open Today control opens today's
note and the New Gist control opens a blank gist. The Add to Today control opens
the capture sheet, and shortcut-provided text skips it. Captures start
today the way the app does, append Sync's `addToToday` edit through the same
`DraftEdit` path as the editor, then leave publishing to autosave.

Both targets read `LibrarySnapshot`, one JSON file in the
`group.dev.gistpad.GistPad` container. It holds the active account, one entity
per gist, and the three recent gists the widget shows: your own, newest edit
first, counting unpublished edits on the phone, without daily notes or archived
gists. It's written atomically with protection until first unlock so StandBy
can read it. No credentials are shared.

Intents run in the main app (`allowedExecutionTargets = .main`), which provides
`DailyNoteActions` through `AppDependencyManager`. An edit from an intent reaches
an open editor as one Undo step.

The GistPad widget is a launcher in small and medium. Its date opens Today, New
Gist runs `NewGistIntent`, and each recent gist runs `OpenGistIntent`. It keeps
the `GistPadToday` kind so widgets already on a Home Screen stay. Timelines never
create a note and only turn the day over, since the app reloads the widget when
the library changes, and on every launch. When the snapshot can't be read, such
as before first unlock, it asks you to open GistPad.

## Validation

`swift test` covers link round-trips and the widget's recent gists counting
your unpublished edits. `PlatformTests` in the app host covers Add to Today from
a Shortcut, and a photo upload inserting its Markdown at the cursor. Installed
widgets, Control Center, Spotlight launches and provisioning are checked on device.
Widget and control intents only run from a plain build. `build-for-testing` links
the packages as shared frameworks, which the system can't find intents in.
