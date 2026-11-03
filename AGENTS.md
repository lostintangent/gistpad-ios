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
- Node.js runs `PreviewRenderer`. The Intelligence eval needs Apple Intelligence on the Mac.
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

**Package tests** run on macOS from the repo root and don't need the slot. `swift test` runs every module's tests. Add `--filter EditorTests` to run one module's.

```sh
swift test
```

**App and UI tests** run on the slot simulator. Add `-only-testing:GistPadTests` or `-only-testing:GistPadUITests` to run one target.

```sh
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

- UI tests drive the real app against the DEBUG fixture GitHub (`FixtureServer` in Sync), never a live account.
- `simctl` can't fold the Duo, so tests and captures run in whatever posture is set. Physical fold transitions are left to the manual pass on the phone.
- The Intelligence eval runs synthetic notes, and live gists you name, through the on-device model on the Mac: `bash scripts/evaluate-intelligence.sh 10`. See `Tools/IntelligenceEval/README.md`.
- `PreviewRenderer` builds Preview's web bundle from `../gistpad.dev` and has its own typecheck, tests and build. See `PreviewRenderer/README.md`.
- Device builds use Release, `generic/platform=iOS`, team `RHFNBL7EG4` and `-allowProvisioningUpdates`. Install with `xcrun devicectl device install app --device 00008160-00041D6C0A200036 <path to GistPad.app>`. The bundle ID is `dev.gistpad.GistPad`.

## Data and secrets

- Tests and tools never write to the user's GitHub account or Supabase metadata without the user's approval in the channel. Read-only checks against real data are fine.
- Never log or commit tokens, sessions or note contents. `Configuration/Public.xcconfig` holds only the public Supabase publishable key.
- Preserve unknown Supabase metadata fields and value shapes, so the web app keeps working.
- Sign-in redirects to `gistpad://auth-callback`, which is already configured in Supabase.
- The key in `Configuration/Public.xcconfig` is the same one gistpad.dev ships in `src/shared/supabase.ts`. If it ever changes, copy the new one in by hand.
- Supabase is pinned to one exact version in `Package.swift` and in the Xcode project, because `GistPadTests` links `Auth` directly. Change both together.

## Captures

- Capture in Dark appearance, on the slot simulator, into `~/Developer/gistpad-work/captures/<task>/`. Attach captures to the channel message that presents them.
- `scripts/capture-matrix.sh` installs the Debug build on the booted Duo, launches it with fixture arguments and saves cover and open screenshots under `DerivedData/Captures`:

  ```sh
  scripts/capture-matrix.sh --name shape-split \
    -- --fixture standard --open shape --mode split
  ```

- Widget and control taps need a plain `xcodebuild build` after `build-for-testing` and before `test-without-building`. `build-for-testing` links the modules as shared frameworks, and the system then fails every widget intent with "There is no metadata for … Intent". Shipping builds link them statically.

## Module map

Code lives in three groups. This is the house style for our Apple projects.

- **App and Extensions** are the Xcode targets that ship: `Sources/App` and `Sources/Extensions/<Name>`. They own signing, entitlements and Info.plist, and wire the modules together.
- **Features** are the user-facing slices, in `Sources/Features/<Domain>`. A feature builds on Shared, and on another feature only when it extends it, as Intelligence extends Editor.
- **Shared** is the core every feature builds on, in `Sources/Shared/<Domain>`. Shared never imports a feature.

Features and Shared are modules of the root `Package.swift`, named by domain, so a folder, its module and its `import` share one name. Each has a compiler-enforced public API. Tests mirror the sources in `Tests/App`, `Tests/UI`, `Tests/Features/<Domain>Tests` and `Tests/Shared/<Domain>Tests`, and `swift test` runs every module's tests on macOS without the simulator or the slot.

| Folder | What it does |
|---|---|
| `Sources/App/Root` | `GistPadApp`, `RootView` and `Library`, the model behind the whole app. |
| `Sources/App/Library` | `GitHubSync`, the library's one actor for GitHub and drafts, plus ordered `Change`s, remote read problems and the last opened file. |
| `Sources/App/Gist` | `File`, `FileSession`, Preview hosting, opening, renaming and conflict review. |
| `Sources/App/DailyNotes` | The Add to Today sheet. |
| `Sources/App/Comments` | The comments inspector and the services behind `CommentsModel`. |
| `Sources/App/Intelligence` | Presents the Intelligence sheet. |
| `Sources/App/Images` | The image picker and upload. |
| `Sources/App/Settings` | Settings, account switching and layout preferences. |
| `Sources/App/System` | `PlatformBridge` and App Shortcuts, which connect the library to intents, widgets and Spotlight. |
| `Sources/App/Captures` | DEBUG fixture launch arguments and the fixture library. |
| `Sources/Extensions/Widgets` | The GistPad widgets and the Add to Today, Open Today and New Gist controls. |
| `Sources/Features/Editor` | `Editor` and its TextKit 2 text view, `EditorView`, `KeyboardBar`, formatting, smart typing, highlighting, front matter and comment highlights. |
| `Sources/Features/Intelligence` | The Ask, Edit and Review sheet and the on-device model. |
| `Sources/Features/Interface` | `LibraryView`, `GistScreen`, comments, tags and the Today button. |
| `Sources/Features/Platform` | App Intents, Spotlight, the widget view and `gistpad://` links. |
| `Sources/Features/Preview` | The offline WebKit Markdown preview and its bridge. |
| `Sources/Shared/Accent` | The personal accent color, its trait and the `isPaneVisible` environment value. |
| `Sources/Shared/Comments` | Comment bodies, threads, quote matching and `CommentsModel`. |
| `Sources/Shared/Sync` | The account, the GitHub client, drafts, publishing, daily notes, the library cache, photo storage, preferences and the DEBUG fixture GitHub. |
| `Tests/App` | App-hosted tests, in folders that mirror `Sources/App`. |
| `Tests/UI` | UI tests for the Library, a gist, daily notes and comments. |
| `PreviewRenderer` | Builds Preview's web bundle from `../gistpad.dev` into `Sources/Features/Preview`. |
| `Tools/IntelligenceEval` | The on-device Intelligence eval. |
| `scripts` | `capture-matrix.sh` and `evaluate-intelligence.sh`. |
| `Configuration` | `Public.xcconfig`. |

Comments, Interface, Platform and Sync document their APIs in a README beside their sources.
