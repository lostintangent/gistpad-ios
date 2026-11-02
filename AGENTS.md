# Working in GistPad Native

How the team works in this repository. The channel purpose holds the charter: what we're building and the principles behind it. This file holds the mechanics.

## Where things are

- This repo is `~/Desktop/gistpad-ios`. The main checkout stays on `main`. Do your work in a worktree.
- The web app at `~/Desktop/gistpad.dev` is the reference for behavior and the source of the Markdown renderer. Read it freely. Never commit to it, and propose any change to it in the channel first.
- `README.md` has the module map. `docs/design-direction.md` and `docs/design-system.md` are the design spec, `docs/sync.md` is the sync contract, and `docs/engineering.md` records engineering choices.

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
- **Batch.** Rebase onto whatever has merged, then do one build, one test run and one capture pass per slot session.

## Branches

- `main` holds shipped builds, tagged `v<version>-<build>`. Each effort has one integration branch, named in the channel's task list.
- Work on your own branch in your own worktree under `~/Developer/gistpad-work/`.
- Commit small checkpoints that compile. Stage only your own files, and never revert or reformat a teammate's work.
- Before fast-forwarding an integration branch, run `git merge-base --is-ancestor <integration> <yours>`. If your branch wasn't cut from the integration branch, merge instead.
- Merge as soon as your slot run is green, so teammates rebase onto real work.

## Building and testing

- Simulator builds and tests follow the README's "Build and run" and "Checks" sections, using the slot simulator's ID. Add `-parallel-testing-enabled NO`, and use a `-derivedDataPath` inside your worktree.
- UI tests drive the real app against the DEBUG fixture GitHub (`FixtureServer` in GistPadSync), never a live account.
- `CommentsInspectorUITests/testCommentsCloseAcrossSheetAndInspectorPostureTransitions` needs a person at the Device Hub fold controls. Leave it to the manual pass.
- Device builds use Release, `generic/platform=iOS`, team `RHFNBL7EG4` and `-allowProvisioningUpdates`. Install with `xcrun devicectl device install app --device 00008160-00041D6C0A200036 <path to GistPad.app>`. The bundle ID is `dev.gistpad.GistPad`.

## Data and secrets

- Tests and tools never write to the user's GitHub account or Supabase metadata without the user's approval in the channel. Read-only checks against real data are fine.
- Never log or commit tokens, sessions or note contents. `Configuration/Public.xcconfig` holds only the public Supabase publishable key.
- Preserve unknown Supabase metadata fields and value shapes, so the web app keeps working.
- Sign-in redirects to `gistpad://auth-callback`, which is already configured in Supabase.

## Captures and evidence

- Capture in Dark appearance, on the slot simulator, into `~/Developer/gistpad-work/captures/<task>/`. Attach captures to the channel message that presents them.
- Designer signs off every visible surface from these captures.
- Back every claim with evidence: test names and counts, captures and commit hashes. Say plainly what you didn't verify.
