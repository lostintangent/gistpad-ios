# How we work on GistPad Native

The channel purpose is the charter: what GistPad Native is and the bar it has to clear. This file is how we build it. Every agent working in this repository follows it.

## Principles

- **Lean on the system.** Use semantic, declarative SDK and SwiftUI behavior wherever it exists: system roles, placements, styles and state. Don't write custom logic or styling to replace what the system provides unless the user asks for it. A custom tint, size, layout calculation or wrapper type has to earn its place, and deleting one is usually the improvement.
- **Happy path first.** Make the mainline path fast and reliable. Don't add defensive code for cases that rarely or never happen. Prefer deleting edge-case machinery over adding it, and keep sync as simple as the web's contract in `docs/sync.md`.
- **Modern and idiomatic.** Use the newest APIs the current iOS SDK offers, the way Apple's own sample code would. No dated patterns and no web-feeling surfaces.
- **One owner per area.** Each module has one owner, named in the channel roster. Agree seams with the owner in the channel instead of editing their code.
- **Evidence over claims.** Back every claim with test names and counts, captures and commit hashes. Say plainly what you didn't verify.

## How a change ships

1. Work arrives as a task in the channel with one owner. Straightforward feedback ships quickly, so start right away.
2. The effort has one integration branch, named in the task list. Branch from it into your own worktree.
3. Work in small compiling commits. Package tests run on macOS at any time.
4. When you need the simulator, take the build slot, rebase onto the integration branch, and do one build, one test run and one capture pass. Merge as soon as it's green, then release the slot.
5. Designer signs off every visible surface from Dark captures.
6. Lead batches the merged work into one build, bumps the build number, installs it on the user's phone, tags `main` as `v<version>-<build>` and merges the integration branch into it.

Simple, high-confidence changes don't wait for steps 4 and 5. When the user asks for a build, Lead builds from the finished branches and installs it right away. Tests, captures and sign-off follow as a check, and anything they catch goes in the next build.

## Where things are

- This repo is `~/Desktop/gistpad-ios`.
- The web app at `~/Desktop/gistpad.dev` is the reference for behavior and the source of the Markdown renderer. Read it freely. Never commit to it, and propose any change to it in the channel first.
- `README.md` tells the product story for people. Keep development detail here instead.
- The [module map](#module-map) below shows where code lives.
- `docs/design.md` is the design spec: how GistPad looks, reads and moves.
- `docs/sync.md` is the sync contract: drafts, publishing and daily notes.
- `docs/engineering.md` records engineering choices the code doesn't show.
- `docs/capture-matrix.md` is the launch contract for captures and fixtures.
- `docs/platform-27.2.md` lists iOS and macOS 27.2 APIs the app could adopt.

## Toolchain

- Run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` first, because `xcode-select` points at the Command Line Tools. Never change `xcode-select`, and never use `sudo`.
- We use the Xcode 27.2 SDK with an iOS 27.2 minimum and the Swift 6 language mode. Unit and package tests use Swift Testing. UI tests use XCUITest.
- Device builds need Apple Developer team `RHFNBL7EG4`.
- Node.js runs `PreviewRenderer` and `scripts/sync-public-config.mjs`. The Intelligence eval needs Apple Intelligence on the Mac.
- Check API names against the installed SDK and developer.apple.com, not memory.

## The build slot

The machine overloads, so the whole channel shares one simulator and one heavy job at a time.

- **One simulator:** "GistPad 27.2" (`9D572007-6DFF-4AE9-8EF8-742F1B5891D1`), an iPhone Duo on iOS 27.2. Never create or boot another.
- **Heavy jobs need the slot:** any `xcodebuild` build or test, simulator run, capture pass, device build or eval. `swift test` on macOS is light and doesn't need it.
- **Acquire it atomically.** If this fails, someone holds the slot. Read the file and wait. When several people are queued, follow the order posted in the channel.

  ```sh
  ( set -o noclobber; printf 'owner: <name> (@handle)\ntask: <task id and summary>\n' > /tmp/gistpad-slot.lock )
  ```

- **Release it** with `rm /tmp/gistpad-slot.lock` the moment you're done, and say so in the channel.

## Branches

- Work on your own branch in your own worktree under `~/Developer/gistpad-work/`. The main checkout stays on `main`.
- Stage only your own files, and never revert or reformat a teammate's work.
- Before fast-forwarding an integration branch, run `git merge-base --is-ancestor <integration> <yours>`. If your branch wasn't cut from the integration branch, merge instead.

## Building and testing

Everything here except package tests needs the slot. Use a `-derivedDataPath` inside your worktree. `DEVICE_ID` is the slot simulator's ID above.

**Build and run** on the booted slot simulator. The build is also the typecheck.

```sh
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app
xcrun simctl launch booted dev.gistpad.GistPad
```

Debug builds take fixture launch arguments, such as `--fixture standard --open shape --mode split`. A fixture runs against an in-memory GitHub, with no account. `docs/capture-matrix.md` is the contract for these flags.

**Package tests** run on macOS and don't need the slot:

```sh
swift test --package-path Packages/GistPadEditor
```

**App and UI tests** run on the slot simulator. Add `-only-testing:GistPadTests` or `-only-testing:GistPadUITests` to run one target.

```sh
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

- UI tests drive the real app against the DEBUG fixture GitHub (`FixtureServer` in GistPadSync), never a live account.
- `simctl` can't fold the Duo, so tests and captures run in whatever posture is set. Physical fold transitions are left to the manual pass on the phone.
- The Intelligence eval runs synthetic notes, and live gists you name, through the on-device model on the Mac: `bash scripts/evaluate-intelligence.sh 10`. See `Tools/IntelligenceEval/README.md`.
- `PreviewRenderer` builds Preview's web bundle from `../gistpad.dev` and has its own typecheck, tests and build. See `PreviewRenderer/README.md`.
- Device builds use Release, `generic/platform=iOS`, team `RHFNBL7EG4` and `-allowProvisioningUpdates`. Install with `xcrun devicectl device install app --device 00008160-00041D6C0A200036 <path to GistPad.app>`. The bundle ID is `dev.gistpad.GistPad`.

## Data and secrets

- Tests and tools never write to the user's GitHub account or Supabase metadata without the user's approval in the channel. Read-only checks against real data are fine.
- Never log or commit tokens, sessions or note contents. `Configuration/Public.xcconfig` holds only the public Supabase publishable key.
- Preserve unknown Supabase metadata fields and value shapes, so the web app keeps working.
- Sign-in redirects to `gistpad://auth-callback`, which is already configured in Supabase.
- `Configuration/Public.xcconfig` is generated by `node scripts/sync-public-config.mjs`, which reads `../gistpad.dev/src/shared/supabase.ts` and rejects any key that isn't public.
- Supabase is pinned to one exact version in `Packages/GistPadSync/Package.swift` and in the Xcode project, because `GistPadTests` links `Auth` directly. Change both together.

## Captures

- Capture in Dark appearance, on the slot simulator, into `~/Developer/gistpad-work/captures/<task>/`. Attach captures to the channel message that presents them.
- `scripts/capture-matrix.sh` installs the Debug build on the booted Duo, launches it with fixture arguments and saves cover and open screenshots under `DerivedData/Captures`:

  ```sh
  scripts/capture-matrix.sh --name shape-split \
    -- --fixture standard --open shape --mode split
  ```

## Module map

Feature code lives in local packages, so parallel work doesn't churn `project.pbxproj`. The app target owns signing and wires the packages together.

| Module | What it does |
|---|---|
| `Packages/GistPadAccent` | The personal accent color, its trait and the `isPaneVisible` environment value. |
| `Packages/GistPadComments` | Comment bodies, threads, quote matching and `CommentsModel`. |
| `Packages/GistPadEditor` | `Editor` and its TextKit 2 text view, `EditorView`, `KeyboardBar`, formatting, smart typing, highlighting, front matter and comment highlights. |
| `Packages/GistPadIntelligence` | The Ask, Edit and Review sheet and the on-device model. |
| `Packages/GistPadInterface` | `LibraryView`, `GistScreen`, comments, tags and the Today button. |
| `Packages/GistPadPlatform` | App Intents, Spotlight, the widget view and `gistpad://` links. |
| `Packages/GistPadPreview` | The offline WebKit Markdown preview and its bridge. |
| `Packages/GistPadSync` | The account, the GitHub client, drafts, publishing, daily notes, the library cache, photo storage, preferences and the DEBUG fixture GitHub. |
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
| `GistPadWidgets` | The GistPad widget and the Add to Today and Open Today controls. |
| `GistPadTests` | App-hosted tests, in folders that mirror `GistPad`. |
| `GistPadUITests` | UI tests for the Library, a gist, daily notes and comments. |
| `PreviewRenderer` | Builds Preview's web bundle from `../gistpad.dev` into `GistPadPreview`. |
| `Tools/IntelligenceEval` | The on-device Intelligence eval. |
| `scripts` | `capture-matrix.sh`, `evaluate-intelligence.sh` and `sync-public-config.mjs`. |
| `Configuration` | `Public.xcconfig`. |

Packages with their own README (GistPadComments, GistPadInterface, GistPadPlatform, GistPadSync) document their APIs there.
