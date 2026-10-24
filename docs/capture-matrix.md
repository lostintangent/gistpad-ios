# Duo capture matrix

Use one current simulator build and a synthetic fixture for every surface review. The shared Mac runs **one simulator only**. Reserve its exclusive capture slot before running this script. Never overlap a native test run or boot a second device for captures.

```sh
scripts/capture-matrix.sh --screen library --state populated
```

The command installs `DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app`, records build/device metadata and display enumeration, and captures cover/open x light/dark x Large/AX3. It defaults to the shared **GistPad Intelligence** Duo (`D121BF28-CFCF-4020-802D-2C81D38F12E2`), which must already be booted. It never boots a simulator automatically. `CAPTURE_DEVICE` or `--device` can name a replacement only after the shared device is shut down and the slot is reassigned. `--contrast both` adds eight increased-contrast captures. It restores the simulator's appearance, contrast and content-size preferences on exit. It does not erase application data or change a hardware device.

`simctl` exposes `primary` (cover) and `primary-1` (inner), but has no public fold/posture command in Xcode 27.1. The script therefore pauses for an actual posture change in Device Hub before each group. Select the assigned shared Duo in Device Hub's sidebar, then use its **Closed** or **Open** posture button. Capturing a different framebuffer alone is not evidence that the app adapted to that posture.

For background automation, supply an absolute `--posture-hook` executable accepting the simulator UDID and `cover`/`open`, or run one already-configured pose with `--pose cover --posture-ready`. The caller is responsible for verifying the posture. Never label a resized window or inactive framebuffer as a folded/open app.

## App route contract

The app receives `--capture-screen NAME --capture-state NAME` on each launch. Capture routes must be debug-only, use synthetic content and avoid connecting to an account. Library, note and editor routes should preserve the same deterministic fixture. Relevant empty/error/sheet states are separate named fixture states. Unknown routes must show an explicit diagnostic rather than silently opening a default screen.

Launches restart the app to make each capture independent. Do not run against an active editing session. A real keyboard and continuity sequence are separate requirements where relevant.

Library and note routes also receive a unique `--capture-ready-token`. The Debug fixture records that token in the app's temporary container only after the Library appears or WebKit reports a completed render. The script waits up to 45 seconds and fails without a screenshot if readiness is absent. This prevents a cold, blank WebKit view from silently becoming evidence. A preview error is itself a ready error surface and remains recorded in the readiness JSON. Other routes use the configured settling interval and still require inspection.

For the focused reading review, pass `--screen note --capture-reading-fixture`. This loads `PreviewFixtures.readingPolish` through the real native note screen, with outline, calculations, neutral and authored diagrams, aligned tables and disclosure. The readiness JSON identifies `reading-polish`, and the build metadata records the flag. Use a separate evidence directory and frozen build from the baseline notebook matrix. Launching the Debug app with `--capture-reading-fixture` alone also selects the synthetic note route, never a live account.

`--screen library --state tag-audit` exercises a long full-name label, two-label overflow, white, black, saturated yellow and missing tag colors. `--screen note --state today` shows the explicit dated Today landing without staging or publishing a note. `--screen note --state tag-editor` opens the native Tags sheet with local-only choices and an intentionally failing synthetic save callback for Retry review. `tag-readonly` opens its nonmutating version. Read-only source fixtures pass disabled task-edit capability to the preview. Tag metadata capability remains independent of GitHub source access. These use synthetic values and the same readiness contract.

`--screen photos` supports `editor`, `notice`, `picker`, `pending`, `multiple` and `unpublished`. It uses in-memory drafts, synthetic image bytes and an offline-only upload transport. The editor requests focus once it attaches, but never behind the notice or picker. Photos acceptance requires whole-display screenshots with the actual system keyboard and accessory. The separate `NotebookPhotoLayoutProbe` records only its app window, not the system keyboard window. It checks the shelf's inset-adjusted visible height and the source area remaining below the actual navigation bar.

Evidence contains `matrix.tsv`, `build.txt`, `displays.txt`, `settings-before.txt`, readiness JSON and individually named PNGs. Submit the PNGs as channel attachments. Inspect them for correct route, active screen, fixture, keyboard and clipping before asking for Designer sign-off. The capture command does not itself certify accessibility, continuity, frame time, physical fold behavior or design approval.
