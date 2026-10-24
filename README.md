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

Debug capture launches accept `--capture-screen library|note|editor|focus`. Library and note use a short interface-review fixture and the actual screen package, with populated/empty/error/offline/readonly states. Editor uses the long multilingual source fixture. Focus uses the shared all-syntax renderer fixture. `--long-fixture` also selects the long document outside interface captures. All fixture content is synthetic.

Focus uses `ArrangementView` to adapt source and preview around the available display regions, backed by the same document session.

## Checks

```sh
swift test --package-path Packages/GistPadEditor
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID,arch=arm64' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The package tests cover UTF-16 source coordinates, duplicate-task mutations, invalid ranges, Writing Tools exclusions and the multilingual fixture. iOS unit tests exercise the actual TextKit 2 view, repeated width changes, selection, undo and programmatic marked text. Programmatic `setMarkedText` is **not** evidence that the real Japanese keyboard's candidate session survives a physical fold.

The opt-in **GistPadFoldProbe** test scheme keeps a programmatic Japanese marked range alive while Device Hub changes actual simulator posture. Run only `DuoPostureProbe`, then change Closed to Open, Partially Open and Closed within two minutes. It records checkpoints automatically and finishes on return to the cover width. Its result attachment records window widths, exact source-byte/selection checks and stable editor identity. Normal test runs skip this interactive probe.

For manual continuity testing, edit the long fixture, begin Japanese composition, change Duo posture, toggle Library/Focus, and undo. The footer's editor UUID must not change. Confirm the source text and selection, not only the picture. Actual Japanese IME, keyboard/handwriting input, Writing Tools and hardware fold behavior remain device gates.

The connected app preserves one source session per durable draft and serializes each local generation before acknowledging a device save. It restores the last account-scoped note/file, otherwise opens an existing Today, otherwise shows a dated landing with an explicit Start action. Launching and changing display posture never create or publish a note. New notes begin as durable local drafts, without a synthetic remote gist. Missing remote notes keep recoverable local text.

Ordinary multi-file notes follow the web default: the newest file in a consistently dated Markdown series, otherwise `README.md`, otherwise the first supported file. Explicit file selection is preserved. Daily Notes remains an intentional exception: its default is today's file, never an older-day fallback.

Search uses cached content and local drafts, supports quoted phrases and `tag:ID`, `tag:"Tag name"` or `#TagName`, and reports incomplete/stale coverage. Daily rows route to their exact files and use real task progress when content is available. Intentionally deleted, clean daily files do not return as historical rows. Library refresh never replaces active input.

Rename, file creation, stars, pins, archive and confirmed deletion use serialized actions. Tags, membership and pins use the signed-in Supabase profile, while GitHub owns content and stars. Source permissions do not make personal profile tags read-only. Deletion retains unsynced drafts and recovery history. Saved-file links use the GistPad share route and disclose that a secret link exposes the saved GitHub version. Sharing current changes requires explicit Save & Share, or exporting draft text.

Conflict review displays byte-exact source changes, preserves the original, freshly verifies the remote version and applies a chosen draft as one undoable, durable local edit. Review never publishes, and its choice durably pauses autosave until an explicit Save to GitHub. Photos use a retained per-draft controller and the same durable edit boundary.

When the signed-in profile enables autosave, a durable local draft publishes after five quiet foreground seconds. Composition, Writing Tools, recovery, conflicts, uncertain attempts and account switching block it. The coordinator rechecks the accepted generation and foreground policy after its fresh remote read, before any write. Leaving the foreground cancels pending timers. Backgrounding finishes queued local persistence only and never initiates publication.

Live Focus hides the Library and arranges the retained source session beside preview in one native navigation container. Account switching first offers to keep the original account's drafts or export a JSON source backup, after local persistence finishes. No drafts are discarded or published by switching. Archive offers Undo, guarded by a fresh byte-exact metadata check so a newer web rename is never overwritten. Reopening a retained note, refreshing the Library or returning to the foreground inspects remote changes without replacing active source, selection or Undo. A changed remote file becomes the normal explicit conflict review, including for a previously clean draft. Native design/continuity acceptance and the live-account round trip remain separate gates.

## Module ownership

- `GistPad/` and `GistPad.xcodeproj`: native shell, signing, navigation and integration
- `Packages/GistPadEditor`: canonical source session, persistent `UITextView`, highlighting and editor fixtures/tests
- `Packages/GistPadPreview`: independent offline WebKit renderer and typed bridge
- `Packages/GistPadInterface`: Library, note chrome, save states and reviewed theme assets
- `Packages/GistPadSync`: authentication, typed GitHub operations, durable drafts and reconciliation
- `PreviewRenderer/`: web-renderer build tooling, sourced from sibling `../gistpad.dev`

Keep feature implementation in local packages so independent work does not churn the project file. No credentials, real gist content or generated Xcode user state belong in this repository.
