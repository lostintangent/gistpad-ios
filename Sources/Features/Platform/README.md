# Platform

Widgets, controls, Shortcuts and Spotlight open the app with `gistpad://` links
for Today, Add to Today, a new gist, a gist's file and a gist that's only on the phone.
`GistPadLink` reads and writes them, and `PendingLink` hands one to the app,
which opens it through its ordinary navigation.
Receiving a link never publishes. The sign-in callback belongs to Store's account sign-in.

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

`GistEntity` also adopts the iOS 27 notes schema. Each Markdown file is a
note in its gist's `GistFolderEntity`, under the active `GistAccountEntity`.
RootView names the displayed file as the entity of the editor, the preview and
a foreground `NSUserActivity`. Only a query for that note while GistPad is
active gets its live body, which the bridge reads from the editor with front
matter stripped by `Syntax.contentStart(in:)`. Spotlight and the shared
snapshot keep titles and snippets but **never full bodies**. Siri answering
questions from the displayed body remains unproven until a phone test.

The schema creates a note, with optional content, through the same local draft
as New Gist and opens it. Append uses the editor's durable edit path, and
renaming or pinning a gist uses the library's metadata actions. Attachments,
pinning on create, choosing a gist, moving a note and a combined
rename-plus-pin are refused rather than silently ignored. There's no body
rewrite or Q&A.

Open Gist, Open Today, Add to Today and New Gist are App Shortcuts, and the
last three are also controls. The Add to Today control opens the capture
sheet, and shortcut-provided text skips it. Captures start today the way the
app does, append Store's `DailyNote.addition` through the same durable edit
as Siri's append, and leave publishing to autosave.

Intents run in the main app (`allowedExecutionTargets = .main`), which provides
`PlatformActions` through `AppDependencyManager`. An edit from an intent reaches
an open editor as one Undo step.

Both targets read `LibrarySnapshot`, one JSON file in the
`group.dev.gistpad.GistPad` container. It holds the active account, note
identities and snippets but **not full note bodies**, and the three recent
gists the widget shows: your own, newest edit first, counting unpublished
edits on the phone, without daily notes or archived gists. It's written
atomically with protection until first unlock so StandBy can read it.
No credentials are shared.

The GistPad widget is a launcher in small and medium. Its date opens Today, New
Gist runs `NewGistIntent`, and each recent gist runs `OpenGistIntent`. It keeps
the `GistPadToday` kind so widgets already on a Home Screen stay. Timelines never
create a note and only turn the day over, since the app reloads the widget when
the library changes, and on every launch. When the snapshot can't be read, such
as before first unlock, it asks you to open GistPad. The Today Lock Screen
widget is one round button with GistPad's notebook mark that opens Today.

## Validation

`swift test` covers link round-trips, per-file note identities and front-matter
stripping, and the widget's recent gists counting your unpublished edits.
`PlatformTests` in the app host covers Add to Today from a Shortcut, Siri
create and append on open and closed files, metadata updates, and photo upload
at the cursor. Installed widgets, Control Center, Siri on the phone, Spotlight
launches and provisioning need device checks.
