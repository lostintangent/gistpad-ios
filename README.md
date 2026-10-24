# GistPad Native

A personal, native iPhone notebook backed by GitHub Gists. **Phase 0 only:** a synthetic editor fixture, not a connected notebook. Edits currently live in memory. There is no sign-in, persistence or GitHub publishing yet.

## Requirements

- Xcode 27.1, iOS 27.1 SDK and simulator runtime
- iPhone Duo simulator, or an iPhone running iOS 27.1+
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

Open `GistPad.xcodeproj` to run interactively. Choose the shared **GistPad** scheme and the Duo destination. Hardware builds use bundle ID `dev.gistpad.GistPad`. The app registers `gistpad://auth-callback`, but authentication is not implemented yet. Add that exact redirect URL in Supabase before implementing OAuth.

## Checks

```sh
swift test --package-path Packages/GistPadEditor
xcodebuild -project GistPad.xcodeproj -scheme GistPad \
  -destination 'platform=iOS Simulator,id=DEVICE_ID' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The package tests cover UTF-16 source coordinates, duplicate-task mutations, invalid ranges, Writing Tools exclusions and the multilingual fixture. iOS unit tests exercise the actual TextKit 2 view, repeated width changes, selection, undo and programmatic marked text. Programmatic `setMarkedText` is **not** evidence that the real Japanese keyboard's candidate session survives a physical fold.

For manual continuity testing, edit the long fixture, begin Japanese composition, change Duo posture, toggle Library/Focus, and undo. The footer's editor UUID must not change. Confirm the source text and selection, not only the picture. Actual Japanese IME, keyboard/handwriting input, Writing Tools and hardware fold behavior remain device gates.

## Module ownership

- `GistPad/` and `GistPad.xcodeproj`: native shell, signing, navigation and integration
- `Packages/GistPadEditor`: canonical source session, persistent `UITextView`, highlighting and editor fixtures/tests
- `Packages/GistPadPreview`: independent offline WebKit renderer and typed bridge
- `PreviewRenderer/`: web-renderer build tooling, sourced from sibling `../gistpad.dev`

Keep feature implementation in local packages so independent work does not churn the project file. No credentials, real gist content or generated Xcode user state belong in this repository.
