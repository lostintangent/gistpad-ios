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
- `README.md` has the module map. `docs/design.md` is the design spec, `docs/sync.md` is the sync contract, `docs/engineering.md` records engineering choices, and `docs/capture-matrix.md` covers captures.

## Toolchain

- Run `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` first, because `xcode-select` points at the Command Line Tools. Never change `xcode-select`, and never use `sudo`.
- We use the Xcode 27.2 SDK with an iOS 27.2 minimum and the Swift 6 language mode. Unit and package tests use Swift Testing. UI tests use XCUITest.
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

- Simulator builds and tests follow the README's "Build and run" and "Checks" sections, using the slot simulator's ID. Add `-parallel-testing-enabled NO`, and use a `-derivedDataPath` inside your worktree.
- UI tests drive the real app against the DEBUG fixture GitHub (`FixtureServer` in GistPadSync), never a live account.
- `simctl` can't fold the Duo, so tests and captures run in whatever posture is set. Physical fold transitions are left to the manual pass on the phone.
- Device builds use Release, `generic/platform=iOS`, team `RHFNBL7EG4` and `-allowProvisioningUpdates`. Install with `xcrun devicectl device install app --device 00008160-00041D6C0A200036 <path to GistPad.app>`. The bundle ID is `dev.gistpad.GistPad`.

## Data and secrets

- Tests and tools never write to the user's GitHub account or Supabase metadata without the user's approval in the channel. Read-only checks against real data are fine.
- Never log or commit tokens, sessions or note contents. `Configuration/Public.xcconfig` holds only the public Supabase publishable key.
- Preserve unknown Supabase metadata fields and value shapes, so the web app keeps working.
- Sign-in redirects to `gistpad://auth-callback`, which is already configured in Supabase.

## Captures

- Capture in Dark appearance, on the slot simulator, into `~/Developer/gistpad-work/captures/<task>/`. Attach captures to the channel message that presents them.
