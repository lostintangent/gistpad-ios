# GistPad Native

GistPad Native is a personal iPhone notebook for GitHub Gists and the native version of [gistpad.dev](https://gistpad.dev). It's built with Swift 6 and SwiftUI for iOS 27.2. You write Markdown source, the phone keeps it as a draft, and GistPad publishes it to GitHub ([sync.md](docs/sync.md)). Ask, Edit and Review run on-device with Apple Intelligence.

[AGENTS.md](AGENTS.md) covers how a change ships, the build slot, branches, the toolchain and installing on a device.

## Requirements

- Xcode 27.2 with the iOS 27.2 SDK and simulator runtime.
- The "GistPad 27.2" iPhone Duo simulator, or an iPhone on iOS 27.2 or later.
- Apple Developer team `RHFNBL7EG4` for device builds.
- Node.js for `PreviewRenderer` and `scripts/sync-public-config.mjs`.
- Apple Intelligence on the Mac for `Tools/IntelligenceEval`.

## Build and run

Boot the "GistPad 27.2" simulator, then:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app
xcrun simctl launch booted dev.gistpad.GistPad
```

Debug builds take fixture launch arguments, such as `--fixture standard --open shape --mode split`. A fixture runs against an in-memory GitHub, with no account. [docs/capture-matrix.md](docs/capture-matrix.md) is the contract for these flags.

`Configuration/Public.xcconfig` holds the public Supabase key that gistpad.dev uses. Regenerate it with `node scripts/sync-public-config.mjs`. It reads `../gistpad.dev/src/shared/supabase.ts` and rejects any key that isn't public.

Supabase is pinned to one exact version in `Packages/GistPadSync/Package.swift` and in the Xcode project, because `GistPadTests` links `Auth` directly. Change both together.

## Checks

Typecheck by running the build above.

Package tests run on macOS:

```sh
swift test --package-path Packages/GistPadEditor
```

App and UI tests run on the simulator. `DEVICE_ID` is the "GistPad 27.2" simulator's UDID from `xcrun simctl list devices`.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

Add `-only-testing:GistPadTests` or `-only-testing:GistPadUITests` to run one target. UI tests drive the Debug app against the fixture GitHub.

Captures install the Debug build on the booted Duo, launch it with fixture arguments and save cover and open screenshots in Dark under `DerivedData/Captures`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
scripts/capture-matrix.sh --name shape-split \
  -- --fixture standard --open shape --mode split
```

The Intelligence eval runs synthetic notes, and live gists you name, through the on-device model on the Mac. See [Tools/IntelligenceEval/README.md](Tools/IntelligenceEval/README.md).

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/evaluate-intelligence.sh 10
```

`PreviewRenderer` has its own typecheck, tests and build. See [PreviewRenderer/README.md](PreviewRenderer/README.md).

## Module map

Feature code lives in local packages, so parallel work doesn't churn `project.pbxproj`. The app target owns signing and wires the packages together.

| Module | What it does |
|---|---|
| `Packages/GistPadAccent` | The personal accent color, its trait and the `isPaneVisible` environment value. |
| `Packages/GistPadComments` | Comment bodies, threads, quote matching and `CommentsModel`. [README](Packages/GistPadComments/README.md) |
| `Packages/GistPadEditor` | `Editor` and its TextKit 2 text view, `EditorView`, `KeyboardBar`, formatting, smart typing, highlighting, front matter and comment highlights. |
| `Packages/GistPadIntelligence` | The Ask, Edit and Review sheet and the on-device model. |
| `Packages/GistPadInterface` | `LibraryView`, `GistScreen`, comments, tags and the Today button. [README](Packages/GistPadInterface/README.md) |
| `Packages/GistPadPlatform` | App Intents, Spotlight, the Today widget view and `gistpad://` links. [README](Packages/GistPadPlatform/README.md) |
| `Packages/GistPadPreview` | The offline WebKit Markdown preview and its bridge. |
| `Packages/GistPadSync` | The account, the GitHub client, drafts, publishing, daily notes, the library cache, photo storage, preferences and the DEBUG fixture GitHub. [README](Packages/GistPadSync/README.md) |
| `GistPad/App` | `GistPadApp`, `RootView` and `Library`, the model behind the whole app. |
| `GistPad/Library` | `GitHubSync`, the library's one actor for GitHub and drafts, plus ordered `Change`s, remote read problems and the last opened file. |
| `GistPad/Gist` | `File`, `FileSession`, Preview hosting, opening, renaming and conflict review. |
| `GistPad/DailyNotes` | The Add to Today sheet. |
| `GistPad/Comments` | The comments inspector and the services behind `CommentsModel`. |
| `GistPad/Intelligence` | Presents the Intelligence sheet. |
| `GistPad/Photos` | The photo picker and upload. |
| `GistPad/Settings` | Settings, account switching and layout preferences. |
| `GistPad/System` | `PlatformBridge` and App Shortcuts, which connect the library to intents, widgets and Spotlight. |
| `GistPad/Captures` | DEBUG fixture launch arguments and the fixture library. |
| `GistPadWidgets` | The Today widget and the Add to Today and Open Today controls. |
| `GistPadTests` | App-hosted tests, in folders that mirror `GistPad`. |
| `GistPadUITests` | UI tests for the Library, a gist, daily notes and comments. |
| `PreviewRenderer` | Builds Preview's web bundle from `../gistpad.dev` into `GistPadPreview`. |
| `Tools/IntelligenceEval` | The on-device Intelligence eval. |
| `scripts` | `capture-matrix.sh`, `evaluate-intelligence.sh` and `sync-public-config.mjs`. |
| `Configuration` | `Public.xcconfig`. |

## Docs

- [design.md](docs/design.md): how GistPad looks, reads and moves.
- [sync.md](docs/sync.md): how drafts, publishing and daily notes work.
- [engineering.md](docs/engineering.md): engineering rules the code doesn't show.
- [capture-matrix.md](docs/capture-matrix.md): the launch contract for captures and fixtures.
- [platform-27.2.md](docs/platform-27.2.md): iOS and macOS 27.2 APIs the app could adopt.
