# GistPadInterface

Native Library and note-screen chrome for iOS 27.0 and later. Screen inputs are Sendable value types. The app owns navigation, authentication, editor sessions, rendering and persistence. This package never initiates a network write.

`LibraryView(model:actions:)` belongs in the sidebar of a `NavigationSplitView`. Bind the app's active document to `LibraryModel.selectedNoteID`. Apply `LibrarySnapshot` values without recreating the model so collection, title search and AND-combined tag filters survive updates. Pinned and recent groups are separate. A selected note that stops matching remains in Open document until selection changes. Load failures and cached offline content are explicit states.

`NoteScreen(document:mode:saveState:actions:source:preview:)` belongs inside the detail navigation container. Supply the existing source editor and preview. Both remain mounted across mode changes. Existing notes start in `.reading`, new notes in `.source`, and interrupted sessions retain their existing mode. `NoteAccess` blocks editing incomplete or read-only data.

Provide only supported `NoteActions`. Unavailable optional actions are absent, not dead controls. `didChangeMode` lets the document owner manage its text view's responder status when the user deliberately switches source/preview. A layout or posture change never triggers that callback. File selection invokes `selectFile` and waits for the owner to update `selectedFileID` before dismissing the sheet. Preserve selection, composition, undo and drafts at that boundary.

Save labels are assertions about real persistence. In-memory and unsaved states do not claim a local write. Only a confirmed matching remote version is `.savedToGitHub`. Failure messages must be useful, non-sensitive user-facing explanations. Supply retry/review callbacks for recoverable failures. Share callbacks own the unsaved-version choice and secret-link disclosure before presenting the native share sheet.

`InterfaceFixtures` and SwiftUI previews use synthetic data. The native String Catalog and four-appearance color assets live in the package resource bundle. `scripts/capture-matrix.sh` and `docs/capture-matrix.md` define the shared review workflow. No screen is production-approved until Designer reviews the required Duo evidence.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadInterface
```
