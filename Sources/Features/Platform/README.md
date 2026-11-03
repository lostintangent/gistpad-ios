# Platform

Widgets, controls, Shortcuts and Spotlight open the app with `gistpad://` links
for Today, Add to Today, a new gist, a gist's file and a gist that's only on the phone.
`GistPadLink` reads and writes them, and `PendingLink` hands one to the app,
which opens it through its ordinary navigation.
Receiving a link never publishes. The sign-in callback stays with Auth.

gistpad.dev links open in the browser. The app doesn't claim them, because that
needs the web's `apple-app-site-association` file deployed first.

## System surfaces

`GistEntity` is an `IndexedEntity`, one per Markdown file, with its title, tags
and a snippet, indexed with complete file protection. Opening one opens the
gist the way the Library does. `GistEntityQuery` resolves identifiers and
strings for the signed-in account and answers the system's reindex requests.
The app updates the index in the background after each snapshot, so nothing
waits on Spotlight, and deletes just the files that went away since the last
one, including while the app wasn't running.

For the Siri notes prototype, each Markdown file is a note in its gist's
`GistFolderEntity`, under the active `GistAccountEntity`. `GistEntity` adopts
the iOS 27 notes schema. The editor text view, preview and foreground
`NSUserActivity` identify the displayed file. Only a query for that visible
note while GistPad is active receives its live body from the editor, with
front matter stripped by `FrontMatter.contentStart(in:)`. Spotlight and the
shared snapshot keep titles and snippets but **never full bodies**. The
schema creates a named note through the existing new-gist draft, appends
text, and renames or pins an existing gist. It does not support arbitrary
body rewrites or Q&A. Siri answering questions from the displayed body
remains unproven until a phone test.

Open Gist, Open Today, Add to Today and New Gist are App Shortcuts. Add to Today,
Open Today and New Gist are also controls. The Open Today control opens today's
note and the New Gist control opens a blank gist. The Add to Today control opens
the capture sheet, and shortcut-provided text skips it. Captures start
today the way the app does, append Sync's `addToToday` edit through the same
`DraftEdit` path as the editor, then leave publishing to autosave.
The notes-schema create uses the same local draft as New Gist and opens it
through its saved link. Its content can be supplied when creating; adding
attachments, pinning immediately or placing it in an existing gist is
explicitly unsupported. Append uses the same durable edit path. Updating
a gist's name or pin uses the library's existing metadata actions. A move
between gists, an attachment update or a combined rename-plus-pin is
refused, rather than silently ignored.

Both targets read `LibrarySnapshot`, one JSON file in the
`group.dev.gistpad.GistPad` container. It holds the active account, note
identities and snippets but **not full note bodies**, and the three recent
gists the widget shows: your own, newest edit first, counting unpublished
edits on the phone, without daily notes or archived gists. It's written
atomically with protection until first unlock so StandBy can read it.
No credentials are shared.

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

`swift test` covers link round-trips, per-file note identities and front-matter
stripping, and the widget's recent gists counting your unpublished edits.
`PlatformTests` in the app host covers Add to Today from a Shortcut, Siri
create and append on open and closed files, metadata updates, and photo upload
at the cursor. Installed widgets, Control Center, Siri on the phone, Spotlight
launches and provisioning need device checks.
Widget and control intents only run from a plain build. `build-for-testing` links
the packages as shared frameworks, which the system can't find intents in.
