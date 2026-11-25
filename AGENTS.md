# How we work on GistPad Native

The channel purpose is the charter: what GistPad Native is and the bar it has to clear. This file is how we build it. Every agent working in this repository follows it.

## Principles

- **Lean on the system.** Use semantic, declarative SDK and SwiftUI behavior wherever it exists: system roles, placements, styles and state. Don't write custom logic or styling to replace what the system provides unless the user asks for it. A custom tint, size, layout calculation or wrapper type has to earn its place, and deleting one is usually the improvement.
- **Happy path first.** Make the mainline path fast and reliable. Don't add defensive code for cases that rarely or never happen. Prefer deleting edge-case machinery over adding it, and keep sync as simple as the web's contract in `docs/sync.md`.
- **Modern and idiomatic.** Use the newest APIs the current iOS SDK offers, the way Apple's own sample code would. No dated patterns and no web-feeling surfaces.
- **Name every platform gap.** Code that exists only because the platform falls short, such as a missing API, a bug or a framework we drop below, starts with a `// Platform gap:` comment. It says what the system doesn't do and what would let us delete the code, like `// Platform gap: SwiftUI's WebView has no edit menu on iOS. Remove this wrapper when webViewContextMenu ships for iOS.` When a new SDK or beta lands, run `grep -rn "Platform gap:" Sources` and retry each one.
- **One owner per area.** Each module has one owner, named in the channel roster. Agree seams with the owner in the channel instead of editing their code.
- **Evidence over claims.** Back every claim with test names and counts, captures and commit hashes. Say plainly what you didn't verify.

## How a change ships

1. Work arrives as a task in the channel with one owner. Straightforward feedback ships quickly, so start right away.
2. The effort has one integration branch, named in the task list. Branch from it into your own worktree.
3. Work in small compiling commits. Package tests run on macOS at any time.
4. When you need the simulator, take the build slot, rebase onto the integration branch, and do one build, one test run and one capture pass. Merge as soon as it's green, then release the slot.
5. Designer signs off every visible surface from Dark captures.
6. Lead batches the merged work into one build, bumps the build number, installs it on the user's phone, tags `main` as `v<version>-<build>`, merges the integration branch into it and pushes `main` and the tag to `origin`.

Simple, high-confidence changes don't wait for steps 4 and 5. When the user asks for a build, Lead builds from the finished branches and installs it right away. Tests, captures and sign-off follow as a check, and anything they catch goes in the next build.

## Where things are

- This repo is `~/Desktop/gistpad-ios`, public at [lostintangent/gistpad-ios](https://github.com/lostintangent/gistpad-ios). Only `main` and build tags are pushed, and working branches stay local.
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
- Node.js runs `scripts/preview-renderer`. The Intelligence eval needs Apple Intelligence on the Mac.
- Check API names against the installed SDK and developer.apple.com, not memory.
- Indent Swift with 4 spaces, Xcode's default. `.git-blame-ignore-revs` lists whitespace-only commits, and `git config blame.ignoreRevsFile .git-blame-ignore-revs` makes local blame skip them too.

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

Everything here except `swift test` needs the slot. Use a `-derivedDataPath` inside your worktree. `DEVICE_ID` is the slot simulator's ID above.

`GistPad.xcworkspace` holds the project and the root package, because a project alone can't run its own package's tests. Open it in Xcode, and pass `-workspace GistPad.xcworkspace` to every `xcodebuild`.

**Build and run** on the booted slot simulator. The build is also the typecheck.

```sh
xcodebuild -workspace GistPad.xcworkspace -scheme GistPad \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app
xcrun simctl launch booted dev.gistpad.GistPad
```

Debug builds take fixture launch arguments, such as `--fixture standard --open shape --mode split`. A fixture runs against an in-memory GitHub, with no account. `docs/capture-matrix.md` is the contract for these flags.

There are two test commands.

**`swift test`** runs every module's package tests on macOS from the repo root, without the slot. Add `--filter EditorTests` to run one module's. Tests that need UIKit, in Editor, Intelligence and Screens, compile only for iOS, so it skips them.

```sh
swift test
```

**The simulator suite** runs the app tests, the UI tests and those iOS package tests in one command on the slot simulator. Add `-only-testing:` with `GistPadTests`, `GistPadUITests` or a package test target such as `EditorTests` to run one. Leave signing on, because the app group comes from the signed entitlements and `PlatformTests` fail without it.

```sh
xcodebuild -workspace GistPad.xcworkspace -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath DerivedData -parallel-testing-enabled NO test
```

- Package tests cover logic. A test that needs a window, for focus, the keyboard, undo or layout, runs app-hosted in `Tests/App` and opens its window with `UIWindow(windowScene:)` in the app's scene. Package tests run in Xcode's bare `xctest` agent, which has no scene, and `UIWindow(frame:)` is deprecated.
- UI tests drive the real app against the DEBUG fixture GitHub (`FixtureServer` in Store), never a live account.
- UI tests poll with `isTappable` and `text`, never `isHittable` or `value`, which fail the test instead of returning false while an element is missing or off screen.
- `simctl` can't fold the Duo, so tests and captures run in whatever posture is set. Turning a display off with `simctl io screenConfig power` doesn't fold it either, and it can leave the simulator stuck in its compact posture. Change posture by hand with Device Hub's display switch. Physical fold transitions are left to the manual pass on the phone.
- The slot simulator drifts over a long day. When every sheet takes about 5 s to finish presenting and tests time out on code that passed before, shut down and boot the slot simulator, never a new one, before suspecting the code.
- When every UI test fails at `app.launch()` with "does not have a process ID" while `xcrun simctl launch` still works, the simulator's `testmanagerd` has gone stale. Find it with `pgrep -fl RuntimeRoot/usr/libexec/testmanagerd` and `kill` that PID, and the next run starts a fresh one.
- The Intelligence eval runs synthetic notes, and live gists you name, through the on-device model on the Mac: `bash scripts/evaluate-intelligence.sh 10`. See `scripts/intelligence-eval/README.md`.
- `scripts/preview-renderer` builds Preview's web bundle from the sibling `gistpad.dev` checkout and has its own typecheck, tests and build. See its README.
- The project file is `GistPad.xcodeproj/project.xcproj`, Xcode 27's JSON format. Change settings with `xcrun xcodeproj` rather than by hand. The build number is set once for the whole project and committed with each build: `xcrun xcodeproj setting set CURRENT_PROJECT_VERSION <build>`.
- Device builds use the workspace, Release, `generic/platform=iOS`, team `RHFNBL7EG4` and `-allowProvisioningUpdates`. Install with `xcrun devicectl device install app --device 00008160-00041D6C0A200036 <path to GistPad.app>`. The bundle ID is `dev.gistpad.GistPad`.

## Data and secrets

- Tests and tools never write to the user's GitHub account or Supabase metadata without the user's approval in the channel. Read-only checks against real data are fine.
- Never log or commit tokens, sessions or note contents. `Configuration/Public.xcconfig` holds only the public Supabase publishable key.
- Preserve unknown Supabase metadata fields and value shapes, so the web app keeps working.
- Sign-in redirects to `gistpad://auth-callback`, which is already configured in Supabase.
- The key in `Configuration/Public.xcconfig` is the same one gistpad.dev ships in `src/shared/supabase.ts`. If it ever changes, copy the new one in by hand.

## Captures

- Capture in Dark appearance, on the slot simulator, into `~/Developer/gistpad-work/captures/<task>/`. Attach captures to the channel message that presents them.
- `scripts/capture-matrix.sh` installs the Debug build on the booted Duo, launches it with fixture arguments and saves cover and open screenshots under `DerivedData/Captures`:

  ```sh
  scripts/capture-matrix.sh --name shape-split \
    -- --fixture standard --open shape --mode split
  ```

## Module map

Code lives in three groups. This is the house style for our Apple projects.

- **App and Extensions** are the Xcode targets that ship: `Sources/App` and `Sources/Extensions/<Name>`. They own signing, entitlements and Info.plist, and wire the modules together.
- **Features** are the user-facing slices, in `Sources/Features/<Domain>`. A feature builds on Shared, and on another feature only when it extends it, as Intelligence extends Editor. The one exception is Model, which builds the view state Screens defines, such as `LibraryState` and `GistDetails`. That keeps Screens buildable and testable without Model, so views that need Model live in App.
- **Shared** is the core every feature builds on, in `Sources/Shared/<Domain>`. Shared never imports a feature.

Features and Shared are modules of the root `Package.swift`, named by domain, so a folder, its module and its `import` share one name. Each has a compiler-enforced public API. Tests mirror the sources in `Tests/App`, `Tests/UI`, `Tests/Features/<Domain>Tests` and `Tests/Shared/<Domain>Tests`, and `swift test` runs every module's tests on macOS without the simulator or the slot.

| Folder | What it does |
|---|---|
| `Sources/App/Root` | `GistPadApp` and `RootView`, which starts the `GistPadModel` and shows the library and the open file, with the layout preferences and the background time that lets a publish finish. |
| `Sources/App/Gist` | Preview hosting, the opening spinner and conflict review. |
| `Sources/App/DailyNotes` | The Add to Today sheet. |
| `Sources/App/Comments` | `CommentsPresentation`, the comments inspector with its conversation and composer, and the services behind `CommentsModel`. |
| `Sources/App/Tags` | Presents the tag editor for the open gist. |
| `Sources/App/Intelligence` | Presents the Intelligence sheet. |
| `Sources/App/Images` | The image picker and upload. |
| `Sources/App/Platform` | `PlatformBridge` and App Shortcuts, which connect the model to intents, widgets and Spotlight. |
| `Sources/App/Captures` | DEBUG fixture launch arguments and the fixture library. |
| `Sources/Extensions/Widgets` | The GistPad widgets and the Add to Today, Open Today and New Gist controls. |
| `Sources/Features/Editor` | `Editor` and its TextKit 2 text view, `EditorView`, `KeyboardBar`, formatting, smart typing, highlighting, front matter and comment highlights. |
| `Sources/Features/Intelligence` | The Ask, Edit and Review sheet and the on-device model, foldered as `Ask`, `Edit` and `Review`, the `Model` they share and the `Sheet`. |
| `Sources/Features/Model` | `GistPadModel`, `GistFile` and `GistFileEditor`: the account, the list, the files you've opened and every verb, one file per scenario. |
| `Sources/Features/Screens` | The views, foldered by capability: `Library` with the Today button, `Gist` with renaming, `Tags`, and `Settings` with the account. The GitHub status control and toolbar toggles both screens use stay at the root. |
| `Sources/Features/Platform` | App Intents and Siri's notes schema, Spotlight, the widget view and `gistpad://` links, a file for each system surface. |
| `Sources/Features/Preview` | The offline WebKit Markdown preview and its bridge. |
| `Sources/Shared/Appearance` | The personal accent color, its trait and `.accent(savedHex:)` modifier, and the `isPaneVisible` environment value. |
| `Sources/Shared/Comments` | Comment bodies, threads, quotes and their highlights, and `CommentsModel`. |
| `Sources/Shared/Store` | The nouns and where they're kept: gists, the GitHub client, drafts, the cache, the account and its preferences, photo storage and the DEBUG fixture GitHub. |
| `Tests/App` | App-hosted tests, foldered by the capability they cover, and every test that needs a window, such as Editor's focus, formatting and layout tests in `Editor`. |
| `Tests/UI` | UI tests for the Library, a gist, daily notes and comments. |
| `scripts` | Developer tools: `capture-matrix.sh`, `evaluate-intelligence.sh`, which runs the on-device Intelligence eval, the root package's `IntelligenceEval` target in `intelligence-eval`, and `preview-renderer`, which builds Preview's web bundle from the sibling `gistpad.dev` checkout into `Sources/Features/Preview`. |
| `Configuration` | `Public.xcconfig`. |

Comments, Model, Platform, Screens and Store document their APIs in a README beside their sources.
