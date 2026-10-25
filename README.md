# GistPad Native

A personal, native iPhone notebook backed by GitHub Gists. **M3 integration in progress:** the connected Library and native editor now include durable creation, metadata actions, cached search, saved-file sharing and local conflict review. Live sign-in and the approved scratch-gist round trip remain unverified gates. Debug captures and test hosts use clearly labeled synthetic fixtures without account access.

## Requirements

- Xcode 27.1 and its iOS SDK
- iPhone running iOS 27.1+, or its matching simulator runtime
- Duo posture testing uses the iOS 27.1 runtime. iOS 27.0 and earlier are outside the product scope.
- For hardware, Apple Developer team `RHFNBL7EG4`, automatic signing and Developer Mode

Use the full Xcode path without changing the machine's `xcode-select` setting:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Build and run

```sh
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

# Find an existing Duo simulator first.
xcrun simctl list devices available
# If none exists, create one after installing the iOS 27.1 runtime.
xcrun simctl create 'GistPad Duo' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-Duo \
  com.apple.CoreSimulator.SimRuntime.iOS-27-1

# Substitute the returned UUID for DEVICE_ID.
xcrun simctl boot DEVICE_ID
xcrun simctl bootstatus DEVICE_ID -b
xcrun simctl install DEVICE_ID DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app
xcrun simctl launch DEVICE_ID dev.gistpad.GistPad
```

Open `GistPad.xcodeproj` to run interactively. Choose the shared **GistPad** scheme and the matching phone destination. Hardware builds use bundle ID `dev.gistpad.GistPad`. Sign-in uses the registered `gistpad://auth-callback` redirect, already configured in Supabase.

`Configuration/Public.xcconfig` contains the same **public** Supabase publishable key as the web app. It is exposed as `SupabasePublishableKey` in the app's Info.plist. If that public key rotates, run `node scripts/sync-public-config.mjs`. The generator rejects service-role keys. User sessions and GitHub tokens must never enter configuration or source control.

Native fixture tests link the existing Supabase Auth product directly because they construct raw profile metadata. Production code uses typed Sync preferences instead. The app directly links GistPadIntelligence for its Debug evaluation workspace's model APIs. When updating Supabase, keep the exact version in `Packages/GistPadSync/Package.swift` and the Xcode project's test-only package reference aligned.

The shared GistPad scheme includes app-hosted `GistPadTests` and the separate `GistPadUITests` XCUITest target. Real SwiftUI control activation belongs in UI tests, not synthetic accessibility activation inside the app process. Use `-only-testing:GistPadUITests` for the bounded interaction gate, with parallel testing disabled and the shared native slot held.

Run `CommentsInspectorUITests/testCommentsCloseAcrossSheetAndInspectorPostureTransitions` separately, starting Closed. Once the Comments sheet appears, unfold, fold and unfold again without closing it. Fold once more after the test closes and reopens the inspector. Each posture change has a 90-second window. The gate verifies native X dismissal and pinned Library restoration, not just the toolbar's selected state.

Owned, published gists offer Delete in the Library row's long-press menu and trailing swipe actions. Both routes reuse the note screen's existing deletion target and execution path, with the GitHub confirmation anchored to the exact library row. Cancelling closes the swipe and preserves the row, and unpublished/recovery copies never receive remote Delete. `--capture-screen library-delete` runs that real workspace against an isolated in-memory provider for interaction checks, with `--capture-appearance light|dark`. The fixture cannot contact an account or perform a remote write.

Confirmed deletions invalidate older refreshes and immediately leave the Library. Account-scoped deletion records exclude stale list responses and cached content, including after an offline restart, until a later complete GitHub list confirms absence. Library reads and mutations share one GitHub client, explicitly revalidate past HTTP caching, and prevent pre-mutation reads from refilling the ETag cache. Add `--capture-stale-deletion` to the isolated fixture to keep returning deleted rows during refresh checks.

The app root updates the personal-accent trait on its own window scene when the account preference changes and resets it to Sky on sign-out. Sheet content also receives the explicit profile value, including nested tag forms. The personal accent is scoped to Today content, Preview list/task marks and the preference swatch. Navigation, menus, keyboard tools and sheet actions use neutral primary ink, while native alert actions keep their system roles. Source/search input remains system blue, switches keep native state colors and tags retain their own colors. Debug captures use `--capture-accent` for the same scene trait, rather than only changing the displayed picker swatch.

Sign Out uses a native alert with a short account-specific draft-retention message, a system-tinted Cancel action and destructive Sign Out. It never publishes drafts. Tag form titles and action labels use consistent Title Case.

Settings > Writing includes Show Front Matter, off by default. It uses the shared `showFrontmatter` account preference, with the same visible save-error handling as Autosave and Check Spelling.

Home is titled GistPad, with Pinned Gists and Your Gists. Today's date tile sits beside its actual excerpt and remaining tasks, with a filled All done check at completion. Narrow and accessibility compositions wrap instead of squeezing columns. Cached cards, search rows and Today share a Markdown-aware extractor before their existing snippet limits. It skips metadata, title headers and code blocks without changing source or fetching decoration.

Debug capture launches accept `--capture-screen library|note|editor|focus`. Library and note use a short interface-review fixture and the actual screen package, with populated/empty/error/offline/readonly states. Home also accepts `today-done` and `today-no-tasks`. Note's `mode-long` and `mode-emoji` states exercise native title truncation without raising the keyboard. `status-busy`, `status-error` and `status-details` present the shared footer control on home or a real rendered note. Status details readiness requires its actual native recovery control. Editor uses the long multilingual source fixture. Focus uses the shared all-syntax renderer fixture. `--long-fixture` also selects the long document outside interface captures. All fixture content is synthetic.

`--capture-screen note-chrome|note-loading|note-failed|settings|settings-signed-out|tags|account|capture-today` exercises the live native chrome and sheets without an account. Note chrome also accepts `--capture-multi-file`, `--capture-offline` and `--capture-cloud-failure`. These fixtures accept `--capture-accent <hex>` and `--capture-ready-token <UUID>`. After the target native view appears, the app writes `tmp/gistpad-capture-<UUID>.ready` with its window size and text-size category. Today additionally requires a focused native text editor and a visible, settled software keyboard. Do not submit its synthetic content. This marker does not certify preview rendering or physical posture. Native host checks attach Settings, Tags and account frames for design review. Requested Dynamic Type environments in mounted hosts do not replace actual simulator or device text-size evidence.

For compositor-level native menu frames, launch `note-chrome --capture-multi-file` with `--capture-state title-menu|more-menu`. The Debug fixture opens the real native control and waits for all expected commands to remain visible before writing readiness. Capture the simulator's primary display after that marker. UIKit `drawHierarchy` attachments do not faithfully reproduce these glass menus.

The native sheet fixtures also accept `tags --capture-state search|search-empty|new-tag|edit-tag`, `settings --capture-state end|sign-out|accent-save|error`, and `account --capture-state end`. These are presentation fixtures, not user-activation tests. Search opens the actual native search control. New/Edit Tag and Sign Out seed their presentation bindings, while Settings `error` seeds the same inline recovery composition used by a rejected save, retaining the pending color and saved preference. Search and New Tag require the focused field and software keyboard. Debug-only native frame probes verify visible results, error and final controls, and end-scroll records the measured content end. Account end-scroll never activates export or changes accounts. Readiness does not imply a real service failure, successful export, completed account action or exercised form-entry gesture.

The live workspace keeps one native navigation container and a device-local Reading/Edit/Split preference. Split requires at least 640 points of actual detail width. Folding preserves an active edit and the preferred Split arrangement, backed by the same retained source and preview. Real reserved-region and posture acceptance remain device gates.

The native source editor uses the web GitHub theme's Markdown token colors with adaptive Increased Contrast variants. Headings, emphasis, quotations, HTML and ordered markers keep their visible delimiters in the element's color. Code remains monochrome and monospaced. Appearance-only changes resolve dynamic colors without reparsing or changing source, selection or Undo. Each SwiftUI host owns a separate container around the retained text view. Only its current host may update visibility, comments and the formatting accessory, so outgoing host teardown cannot detach or reconfigure the active editor.

Existing notes start at the first visible content line, and explicitly switching Preview to Edit focuses that same start instead of UIKit's default end-of-document selection. Create and an explicit Today action retain their intentional caret-at-end behavior. YAML front matter and following blank lines are hidden by default through TextKit 2 paragraph enumeration. Settings' account-backed Show Front Matter preference exposes them without replacing the retained text view or changing source bytes, generation or Undo. While hidden, selection, Select All and backspace stay within content. Intelligence citations into hidden metadata keep their quoted text with a quiet Front matter label and no source-navigation action. Formatting, Preview, photo insertion and intelligence continue to use full-source UTF-16 coordinates.

To diagnose a device-only blank editor, the live workspace keeps the latest 48 presentation records from the current process in `Library/Application Support/EditorDiagnostics/latest.json`. Opens, mode/width/scene changes and disappearance record source/editor byte counts and equality, mounting/ancestor visibility, window geometry, offsets/insets, native selection and the existing TextKit viewport state. No source, titles, filenames, gist/account IDs, tokens or user instructions are recorded. Diagnostics never force layout, move the selection or change scrolling. The file is suitable for read-only extraction after reproducing the issue.

## Checks

```sh
swift test --package-path Packages/GistPadEditor
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The package tests cover UTF-16 source coordinates, duplicate-task mutations, invalid ranges, Writing Tools exclusions and the multilingual fixture. iOS unit tests exercise the actual TextKit 2 view, repeated width changes, selection, undo and programmatic marked text. Programmatic `setMarkedText` is **not** evidence that the real Japanese keyboard's candidate session survives a physical fold.

Navigation fixtures use the current scene's height and compact bounds, with a synthetic width only for regular-layout checks. They await keyboard dismissal and native navigation/presentation transition completion before removing their windows and restoring the previous key window. Source keyboard fixtures await native appearance before requesting focus. The compact Library round-trip verifies the refocused keyboard's actual on-screen rectangle, both during and after initial keyboard presentation.

The opt-in **GistPadFoldProbe** test scheme keeps a programmatic Japanese marked range alive while Device Hub changes actual simulator posture. Run only `DuoPostureProbe`, then change Closed to Open, Partially Open and Closed within two minutes. It records checkpoints automatically and finishes on return to the cover width. Its result attachment records window widths, exact source-byte/selection checks and stable editor identity. Normal test runs skip this interactive probe.

For manual continuity testing, edit the long fixture, begin Japanese composition, change Duo posture, toggle Library/Focus, and undo. The footer's editor UUID must not change. Confirm the source text and selection, not only the picture. Actual Japanese IME, keyboard/handwriting input, Writing Tools and hardware fold behavior remain device gates.

The connected app preserves one source session per durable draft and serializes each local generation before acknowledging a device save. It restores the last account-scoped note/file, otherwise ensures today's note and opens it quietly without the keyboard. The same quiet default follows sign-in and deletion of the selected note. Sidebar Today, the folded Today card, the Daily Notes empty state and the `.today` route use that same ensure path, intentionally entering Edit with the keyboard. There is no Start interstitial. Missing notes are staged locally before publication, and a failed Today ensure uses the existing failed-open view with Retry. Signed out, the workspace shows the existing GitHub sign-in invitation.

Ordinary multi-file notes follow the web default: the newest file in a consistently dated Markdown series, otherwise `README.md`, otherwise the first supported file. Explicit file selection is preserved. Daily Notes remains an intentional exception: its default is today's file, never an older-day fallback.

Selecting a note replaces the detail target before asynchronous opening begins. Retained drafts and cached source open without a blocking GitHub read. Only an uncached note shows a native redacted placeholder with its own title, never the previous note's editor. Remote inspection happens after presentation and does not replace retained source. Create and an explicit Today action open durable local content in Edit with a one-shot caret-at-end/keyboard request after the editor attaches. Ordinary creation uses the account's cached GitHub identity and does not wait for a Library reload, search or network response.

Leaving an ordinary new note discards its local draft quietly only while its title is empty and its source contains nothing but whitespace. An untouched, unpublished default daily date heading also counts as blank, including a new day in an existing daily gist. Neither kind publishes automatically, even on app background, or starts an unnecessary remote-change comparison. Manual publication remains explicit. The app first finishes local persistence and checks that the note is no longer selected. Published files, typed daily content, custom templates, creation attempts, recovery history and pending photos are preserved. Launch and account restoration remove abandoned blanks before restoring selection. Refresh never removes the currently open note.

`gistpad://library` and the `https://gistpad.dev/` root reveal the actual Library. In compact navigation, they clear the list's navigation selection, supersede pending opens and keep the last note's retained editor available. Autosave-on still publishes when leaving the note, while autosave-off keeps changes local. At regular widths, they reveal the sidebar without changing the open note, source selection or keyboard focus. Completing cold restoration cannot push a dismissed detail back over the Library.

Today's availability, first two source lines and task progress come from account-local metadata, cached content and durable drafts. An empty existing note is not a missing note. An unpublished Today reopens its original local draft without another creation or remote read.

`--capture-screen today --today-fixture missing|existing|cold|signed-out|retry` runs the real workspace against an isolated in-memory daily notebook. Missing and existing fixtures restore an ordinary note first so Today can be tapped. Cold and Retry exercise automatic, keyboard-free opening. The fixture uses the real cached daily staging service and cannot write to an account.

Search uses cached content and local drafts, supports quoted phrases and `tag:ID`, `tag:"Tag name"` or `#TagName`, and reports incomplete/stale coverage. Daily rows route to their exact files and use real task progress when content is available. Intentionally deleted, clean daily files do not return as historical rows. Library refresh never replaces active input.

The note title menu is exclusively for switching and managing files, and appears only on multi-file notes. Rename Note lives in the sectioned More menu, separate from Rename Current File. Healthy save states remain silent. An uncached first open uses redacted native lines, and a failed open retains the requested title with a direct Retry rather than displaying the previous note.

Settings is a native Form reached from the Library account button, with the account's avatar, optional name and GitHub login. Autosave While Writing and Check Spelling use the signed-in profile, and Appearance uses its saved accent color. Failed saves remain explicit. Confirmed Sign Out finishes local persistence, removes the sign-in credentials and clears the current presentation without publishing or deleting account-scoped drafts. Signing back in restores that account's saved selection and local work. Settings captures the originating account and resets unsaved form/picker state on account changes. Tags use one searchable swatch/name/check list with visible Save, a native bottom search control and a single all-files scope footer. Staged edits, failed-save retry and discard confirmation remain intact.

Rename, file creation, stars, pins, archive and confirmed deletion use serialized actions. Tags, membership and pins use the signed-in Supabase profile, while GitHub owns content and stars. Source permissions do not make personal profile tags read-only. After GitHub acknowledges a confirmed deletion, all local drafts, recovery history, queued image bytes, comment drafts and cached/search content for that gist are removed too. Other accounts and gists are unchanged. Saved-file links use the GistPad share route and disclose that a secret link exposes the saved GitHub version. Sharing current changes requires explicit Save & Share, or exporting draft text.

The note's Comments action keeps its high-contrast count inside one composed icon, including when a live fetch supplies the count after presentation. The count uses primary foreground fill, inverse digits and a thin background-colored ring that separates it from the native selected fill. The bubble inverts when selected. Unknown and zero totals have no visual badge, and totals above 99 show `99+`. VoiceOver reads the full known total, and the native toggle retains the inspector's selected state. The same conversation follows native sheet-to-inspector adaptation when folding or unfolding, without clearing its context during the handoff. Closing Comments restores the Library's earlier sidebar visibility.

Conflict review displays byte-exact source changes, preserves the original, freshly verifies the remote version and applies a chosen draft as one undoable, durable local edit. Review never publishes, and its choice pauses timed/note-leave autosave until an explicit Save to GitHub or the app-background save. Unresolved conflicts are never published automatically. Photos use a retained per-draft controller and the same durable edit boundary.

Sync follows the web's save triggers: when the signed-in profile enables autosave, a durable draft publishes after five quiet foreground seconds and on leaving the note. Backgrounding saves all sessions with unpublished changes, even when autosave is disabled, inside one finite iOS background-task lease. Local persistence finishes first. Read-only notes, composition, Writing Tools, recovery, unresolved conflicts, uncertain attempts and account switching remain blocked. Before each write, the coordinator rechecks the accepted generation and the applicable foreground/lease policy. Lease expiry cancels further publication and leaves the durable local drafts intact.

An unconfirmed first creation keeps the source editable and offers Check GitHub for the signed-in account's Gists page. Details offers a confirmed Publish as New Note, with a possible-duplicate warning, or Discard This Copy. Discard removes only that unbound draft, its pending photos and local recovery history. Neither choice searches for a remote match or deletes anything on GitHub.

Intelligence offers whole-note Ask, Edit with a reviewable diff and Review comments using the on-device Apple model. Both the note menu and source accessory open the same retained-session sheet. Account, document and generation checks reject stale results, and applying an edit uses the source's existing local persistence and Undo. Read-only notes support Ask and Review, but exact read-only reference navigation is not yet available.

Live Focus hides the Library and arranges the retained source session beside preview in one native navigation container. Account switching first offers to keep the original account's drafts or export a JSON source backup, after local persistence finishes. No drafts are discarded or published by switching. Archive offers Undo, guarded by a fresh byte-exact metadata check so a newer web rename is never overwritten. Reopening a retained note, refreshing the Library or returning to the foreground inspects remote changes without replacing active source, selection or Undo. A changed remote file becomes the normal explicit conflict review, including for a previously clean draft. Native design/continuity acceptance and the live-account round trip remain separate gates.

## Module ownership

- `GistPad/` and `GistPad.xcodeproj`: native shell, signing, navigation and integration
- `Packages/GistPadEditor`: canonical source session, persistent `UITextView`, highlighting and editor fixtures/tests
- `Packages/GistPadPreview`: independent offline WebKit renderer and typed bridge
- `Packages/GistPadInterface`: Library, note chrome, save states and reviewed theme assets
- `Packages/GistPadSync`: authentication, typed GitHub operations, durable drafts and reconciliation
- `Packages/GistPadComments`: shared comment bodies, thread structure and exact quote matching
- `PreviewRenderer/`: web-renderer build tooling, sourced from sibling `../gistpad.dev`

Keep feature implementation in local packages so independent work does not churn the project file. No credentials, real gist content or generated Xcode user state belong in this repository.
