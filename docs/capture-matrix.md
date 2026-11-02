# Duo capture matrix

Use one current simulator build and the fixture library for every surface review. The shared Mac runs **one simulator only**. Reserve the build slot (`/tmp/gistpad-slot.lock`) before running this script, and never overlap a test run.

```sh
scripts/capture-matrix.sh --name shape-split -- --fixture standard --open shape --mode split
```

The command installs `DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app` and captures cover/open × light/dark × Large/AX3 on the shared **GistPad 27.2** Duo (`9D572007-6DFF-4AE9-8EF8-742F1B5891D1`), which must already be booted. `--pose`, `--appearance` and `--contrast` capture a subset or add increased contrast. Each capture relaunches the app with the arguments after `--` and waits `--settle` seconds. The script restores the simulator's appearance, contrast and text size on exit.

`simctl` has no fold command, so the script pauses for you to set the posture in Simulator before each group. For background runs, pass an absolute `--posture-hook` executable that takes the UDID and `cover`/`open`, or capture one posture that's already set with `--pose open --posture-ready`. The script maps cover and open to the Duo's two framebuffers by width.

## Launch contract

Debug builds accept these arguments. Every fixture is in memory and never touches a real account.

| Argument | Values |
| --- | --- |
| `--fixture` | `standard`, `empty`, `signed-out`, `offline` |
| `--open` | `<gist>`, `<gist>/<file>` or `today` |
| `--mode` | `edit`, `preview`, `split` |
| `--query` | Library search text |
| `--sheet` | `tags`, `settings`, `today`, `intelligence`, `comments` |
| `--accent` | `#RRGGBB` |

`standard` seeds `GistPad/Fixtures/FixtureLibrary.swift`: pinned, tagged, daily, starred and archived gists, a multi-file gist (`shape`) and a gist with comment threads (`highlights`). `offline` caches the same library and then fails every request. UI tests use the same flags through `GistPadUITests/UITestSupport.swift`.

Inspect each image for the right posture, screen and keyboard before asking for Designer sign-off. Captures don't certify accessibility, physical fold behavior or design approval.
