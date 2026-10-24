# Documint iOS spike

This is an isolated, nonshipping experiment. The production Xcode project and its Edit/Preview/Split mode contract do not depend on this package. Raw Edit and the shared gistpad.dev Preview remain unchanged.

## Build and inspect

Requires the existing adjacent `~/Desktop/documint` checkout and its installed Bun dependencies. The bundle builds directly from that source, not a hand-copied fork or its possibly stale `dist` output.

```sh
bun Spikes/Documint/Web/build.ts
bun ~/Desktop/documint/node_modules/typescript/bin/tsc -p Spikes/Documint/Web/tsconfig.json
python3 Spikes/Documint/prepare-app.py /tmp/gp-documint-fresh-source
```

The preparation script archives the current committed GistPad revision into a fresh `/tmp` directory, copies this spike, and links it only in that temporary Xcode project. Once the native slot is acquired, build that app normally and launch it with `--capture-screen documint`. Its isolated workspace has Edit, Rich and Preview choices and a synthetic local note. It never loads an account.

The package contains native bridge, retained-source, WebKit input and five-pair cold-open comparisons. The preparation script also places these tests in the temporary app's real iOS test host. Run the isolated `GistPad` scheme with `-only-testing:GistPadTests/DocumintBridgeTests -only-testing:GistPadTests/DocumintWebKitTests`. The latter measures host creation to each renderer's completion event. These are simulator measurements, not device launch benchmarks.

The isolated project's `DocumintSpike` UI-test scheme records the real iOS accessibility hierarchy, software-keyboard geometry, typed-text transfer back to raw Edit, the actual autocorrect outcome and selection-menu screenshots. It does not enable VoiceOver or equate an accessibility-tree probe with a spoken traversal. Japanese composition requires a separately observed real IME session, not synthetic DOM composition events.

After installing only that temporary build into the shared simulator, run `python3 Spikes/Documint/cold-open.py /tmp/gp-documint-cold-open.json` while holding the slot. It alternates five Rich/Preview pairs, starts a fresh app process for every sample, and waits for a unique native readiness record. Preview samples do not instantiate a hidden Rich WebView. Results include simulator-launch overhead and renderer completion, not a claim of physical-device performance.

## Content and persistence contract

Rich edits are generation-checked `SourceMutation` transactions against the existing `DocumentSession`. The adapter finds a single changed range at composed-character boundaries, retains the source text view and native Undo, and invokes the same `onSourceChange` draft/autosave callback as raw Edit. A byte-identical snapshot never creates a mutation. The browser serializes in-flight edits with acknowledgements instead of allowing two edits to race the same native generation.

Opening a note does not normalize its source. The first actual rich edit serializes Documint's entire semantic document to canonical Markdown, including untouched blocks. The user explicitly accepted canonicalization for this rich-mode experiment. It is not a source-minimal editor.

The bridge contains only document text, identity/generation, edit revisions, resolved appearance and content-free timing/error messages. It never receives credentials, account data or tokens. Resources use a local custom scheme and a nonpersistent data store. CSP prohibits external resource loading and navigation stays inside the bundle. The image fixture deliberately distinguishes raster support from SVG decoding. Remote authored images are blocked for this offline experiment.

## Appearance

The native host resolves SF Body size from Dynamic Type and maps native Light/Dark text, surfaces, separator and system blue into `EditorTheme`. Personal accent is limited to authored list markers and task marks. Contextual controls and headings use primary ink, with blue caret/selection/link roles.

Documint currently exposes one base font size, not independent native heading sizes. Its canvas headings therefore remain proportional to Body. At Body 17/40/53, its H1 is 34/80/106 instead of Preview's accepted 34/52/60. This is a measured upstream capability gap, not a Dynamic Type cap in the host.

## Private-note checks

The browser tests use only loopback resources. `Web/browser-check.js` expects a local server on port 4181 with `Web/`, the synthetic `parity.md`, and `private/{manga,daily,oss}.md`. Personal notes must remain outside the repository in private `/tmp` storage. Their content is omitted from test summaries and screenshots.

`Web/fidelity.ts /tmp/<private-directory>` records parser/serializer normalization counts and local output files. The browser test separately verifies zero-callback idle opens and actual first-edit callbacks, rather than confusing a direct serializer round trip with an automatic save.

The native `privateNoteRoundTrips` test requires those same three files to be copied into the temporary simulator app's `Library/Application Support/DocumintSpike/PrivateFixtures/` directory after installation. It fails if they are absent. It checks idle bytes and callbacks, dispatches one deterministic `beforeinput` character through actual iOS WebKit, records content-free added/removed-line counts and verifies front-matter bytes, `<ins>` counts and exact native Undo. This is a bridge/serialization measurement, not a substitute for the separate software-keyboard typing probe. Do not capture or share screenshots of the private fixtures.

Rendering and native-input acceptance are not implied by the package compiling. Record actual simulator evidence before deciding whether to expose the experiment or replace either existing mode.

## October 24 outcome

**No-go for shipping Rich, including as an opt-in mode. Keep Preview.** The isolated iOS app builds and its seven hosted cases pass. The two real UI probes cover Light/Dark, visible keyboard geometry, source transfer, actual autocorrect outcome, scrolling and native selection-action evidence. A tightened follow-up preserves the untouched heading source exactly, despite a canvas wrapping/paint discrepancy. Native first-character edit counts match the browser: Manga adds/removes 230/234 lines, Daily 2/1, and OSS 6/5, with zero idle rewrites and exact Undo.

The native Rich accessibility subtree lacks authored heading/task/table semantics. Double-tap and long-press did not expose a native edit menu or Writing Tools button in the observed probes. The sample `teh` stayed unchanged. Rich also paints the heading word `page` as `pag` in the captured editing frames, even though native source and Edit retain the final `e`. That visible fidelity failure is a blocker, not a source-loss finding. A bundled PNG renders after the custom scheme returns HTTP status 200. The bundled SVG fails bitmap decoding. Five final fresh-process pairs measure 6.10 s Rich versus 7.72 s Preview medians including simulator launch overhead, but an earlier run was 3.24/3.30 s. These noisy completion events do not establish a performance advantage or image-complete first paint.

The upstream gates are complete canvas text painting, semantic document accessibility, native-compatible autocorrection/selection/system editing, image decoding and independent heading metrics. Pluggable GistPad-dialect rendering is additional parity work. Actual spoken VoiceOver, Japanese IME, a complete Writing Tools session, long-note editing endurance and live draft/network publication remain unverified. The account-free spike never touched the physical Duo or the shipping project.
