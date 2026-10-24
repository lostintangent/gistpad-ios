# GistPadPlatform

Native system entry points share `NotebookRoute`. The router accepts the web's
hash routes and equivalent HTTPS paths, plus `gistpad://` routes for widgets,
Shortcuts and Spotlight. Share links preserve the exact selected filename.
The authentication callback is deliberately excluded and remains owned by Auth.
Unknown hosts, credential-bearing URLs and malformed routes are rejected.

The main app consumes routes through its existing navigation and document-session
handoff. Receiving a link never publishes a note. New-note and Today routes use
the same explicit local staging actions as the Library.

Universal links require the associated-domains entitlement and deployment of
`public/.well-known/apple-app-site-association` from the web repository. Until that
file is deployed, native scheme links work but HTTPS links are not claimed to
open the app.

## System surfaces

`NoteEntity` is an `IndexedEntity` with title, exact filename, tags and a cached
snippet. `NoteEntityQuery` supports identifier and string lookup, plus iOS 27
reindex requests. Entities are indexed using complete file protection. Account
changes and removed notes remove the old entities. Queries and Open Note validate
the currently authenticated account, not just a cached entity ID.

Open Note, Open Today and Add to Today are App Shortcuts. The Add to Today control
opens the native capture sheet. Provided shortcut text needs no duplicate sheet.
Captures pin the destination date, then use `TodayAppend` and the same validated
`SharedDraftCommand` transaction as editor integrations.
The capture sheet opens the exact accepted draft after Add. This hands its
five-second autosave and leave-app publication to the existing editor lifecycle,
including when that daily note was not already open.

Both targets use `group.dev.gistpad.GistPad`. `SharedNotebookStore` is a protected,
atomically replaced presentation snapshot under the existing `SharedStoreLocation`.
It contains only the active account, cached note metadata and accepted Today
tasks. The main app's existing private draft store is not moved or reopened by
extensions. No credentials are shared.

Task intents use the iOS 27 `allowedExecutionTargets = .main` execution policy and
system authentication. They validate account, displayed file, generation and
exact UTF-16 marker. Retained editors receive the durable change through their
one-step Undo path. Conflicts, composition, Writing Tools and stale anchors reject
the mutation. A checked widget task means the local source committed, not that a
GitHub write was acknowledged. Publication uses the existing foreground/background
save paths. A publication failure remains durable and visible in the next snapshot.

The presentation file uses after-first-unlock protection so Lock Screen and
StandBy timeline reads remain available after locking. Widget reads do not create
directories or change attributes. Canonical drafts and credentials retain their
existing unlocked-device-only policies.

The Today widget supports small, medium, all three Lock Screen accessory families
and the system's small-widget StandBy presentation. Timelines never create a note.
Personal task/excerpt content is privacy-sensitive. Before-first-unlock or unavailable content
shows an explicit invitation instead of fabricated tasks.

## Validation

Pure routes, snapshot isolation and durable commands use fake/in-memory data.
`NotebookPlatformTests` additionally covers retained editor Undo, stale tasks,
account/Writing Tools gates, pinned-date capture and main-process intent policy.
Widget view screenshots are hosted native presentations. Installed WidgetKit
execution, Control Center placement, Spotlight launching and provisioning remain
separate device acceptance gates.
