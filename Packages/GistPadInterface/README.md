# GistPadInterface

Native Library and note-screen chrome for iOS 27.1 and later. Screen inputs are Sendable value types. The app owns navigation, authentication, editor sessions, rendering and persistence. This package never initiates a network write.

`LibraryView(model:actions:footer:)` belongs in the sidebar of a `NavigationSplitView`. It uses a continuous reading canvas when compact and the native sidebar style as a companion column. Bind the app's active document to `LibraryModel.selectedNoteID`. Apply `LibrarySnapshot` values without recreating the model so collection, search and AND-combined tag filters survive updates. Default snapshot filtering groups pinned and recent notes separately. A selected note that stops matching remains in Open document until selection changes. Load failures and cached offline content are explicit states. The optional diagnostic footer scrolls with the list.

For app-owned full-text/tag-token search, set `LibraryModel.searchState` to `.searching`, `.results(notes:coverage:)` or `.failed(message:)`. Supplied result row IDs and ordering pass through without a second title, collection or tag filter. The app owns row-to-document/file/draft resolution and invalidates results when the query changes. Coverage distinguishes unavailable content, incomplete file lists and older cached results. A failed or pending search never silently falls back to the title-only filter.

`LibraryModel.today` supplies a pinned date/time zone and optional real task progress. Unknown progress is omitted, not displayed as zero. `TodayLanding(summary:start:)` is the unselected detail when no existing note is available. It never creates anything on appearance. The app performs creation only in `start`, and owns restoring the last account-scoped note/file before choosing this fallback.

`TagLabel` and `TagLabels` share primary-text names, a color dot and an opaque softly tinted surface. Labels wrap at available width and retain full names at large type. Library rows display two labels and a truthful overflow count. `NoteChrome.tags` exposes all gist-level tags in the native Note details sheet without a ribbon over the writing canvas. Selected-row metadata uses primary text against the warm selection surface.

`NoteScreen(document:mode:saveState:actions:source:preview:)` belongs inside the detail navigation container. Supply the existing source editor and preview. Both remain mounted across mode changes. Existing notes start in `.reading`, new notes in `.source`, and interrupted sessions retain their existing mode. `NoteAccess` blocks editing incomplete or read-only data.

Provide only supported `NoteActions`. Unavailable optional actions are absent, not dead controls. `didChangeMode` lets the document owner manage its text view's responder status when the user deliberately switches source/preview. A layout or posture change never triggers that callback. File selection invokes `selectFile` and waits for the owner to update `selectedFileID` before dismissing the sheet. Preserve selection, composition, undo and drafts at that boundary.

Save labels are assertions about real persistence. In-memory and unsaved states do not claim a local write. Only a confirmed matching remote version is `.savedToGitHub`. Failure messages must be useful, non-sensitive user-facing explanations. Supply retry/review callbacks for recoverable failures. Share callbacks own the unsaved-version choice and secret-link disclosure before presenting the native share sheet.

`InterfaceFixtures` and SwiftUI previews use synthetic data. The native String Catalog and four-appearance color assets live in the package resource bundle. `scripts/capture-matrix.sh` and `docs/capture-matrix.md` define the shared review workflow. No screen is production-approved until Designer reviews the required Duo evidence.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadInterface
```
