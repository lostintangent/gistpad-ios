# Offline Markdown preview

Preview renders notes with gistpad.dev's own Markdown code, bundled into a local WebKit page. This folder builds that bundle from the sibling `gistpad.dev` checkout into `Sources/Features/Preview/Resources/Web`, which is checked in, so the app needs no Node, server or network at runtime.

## Build

```sh
cd scripts/preview-renderer
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
```

Rebuild on purpose, when the web's dialect changes. The build takes `remarkInlineSyntax`, `rehypeToc`, `Mermaid`, the calculator and the preview CSS straight from `gistpad.dev/src`, with the plugin order of `MarkdownPreview.tsx`, and `provenance.json` records their SHA-256 hashes. `package.json` lists every package the bundle imports, the web's included, and Vite resolves them all from this folder's lock, so the same web source rebuilds the checked-in bundle byte for byte. When the web's Markdown code adds an import or changes a version, match it here and review the diff in `Resources/Web` before committing.

Two adapters keep the web's code offline and native:

- The calculator's `Function` call becomes a non-executable arithmetic parser (`src/arithmetic.ts`). The adapter throws if that upstream call changes, the build fails if it doesn't run, and `tests/calculations.test.ts` checks it against the original.
- Mermaid's dark-mode hook reads the native appearance (`src/useNativeAppearance.ts`).

## Security

HTML is sanitized before Contents, slugs and task annotation, so scripts, forms, frames, event handlers and arbitrary styles never reach the page. The CSP allows only bundled scripts, styles and fonts, with no network connections, objects or frames. HTTPS and data images load with no referrer and show a fallback when they fail. No tokens or session objects enter WebKit.

## Bridge

The page exposes `window.gistpadPreview` (`src/protocol.ts`): `render`, `setAppearance`, `setViewportInsets`, `commentSegments`, `commentSelection` and `setCommentHighlights`. It posts `ready`, `rendered`, `taskToggle`, `link`, `commentActivate` and `failure` to one handler, `gistpadPreview`.

Native accepts messages only from the bundle's main frame and drops any from an older generation. A task toggle carries the UTF-16 range of the parsed task's marker plus the expected and replacement markers, and native checks them against the current text before applying the edit. `allowsTaskEdits` travels with each render, so read-only checkboxes never emit edits. Links must be http, https or mailto.

## Comments

Quote matching in Shared Comments is authoritative. The page catalogs each sanitized text node outside `pre`, `code` and `svg`, native matches quotes against that catalog, and the page draws the returned ranges. A tapped highlight sends only its segment and range, and native resolves its threads. Add Comment joins the system selection menu and reads the rendered selection only when the menu opens. A selected passage opens its enclosing disclosures and scrolls into view.

## Scrolling and appearance

The web view runs under the bars. UIKit's automatic content inset puts the first line just below them and lets text scroll up under the glass. Native also hands that inset to WebKit as its obscured insets, so a new page paints its first frame below the bars, and passes it to the page as root scroll-padding, so anchors and revealed passages land below them too. A width change keeps the reading passage in place.

Appearance travels apart from Markdown, as CSS variables that `PreviewAppearance` resolves from native traits: semantic colors, the personal accent's roles and Dynamic Type metrics. A change never reparses the note or drops the selection. `docs/design.md` specifies the look.

## Tests and fixtures

- `npm test` covers task ranges with duplicate labels, CRLF and forged raw HTML, comment overlap runs and the text catalog, and the calculator against the web's.
- `swift test --filter PreviewTests` runs the bridge tests on macOS.
- On the simulator, `PreviewTests` also load the all-syntax fixture through the real resource scheme, keep the reading position across width and inset changes, and render again after the web process dies.

`PreviewFixtures.allSyntax`, `readingPolish` and `listMarkers` seed the `guide`, `shape` and `words` gists in the `standard` fixture. `--fixture standard --open highlights` shows comment highlights in the app. WebKit test snapshots aren't visual evidence, so capture the app with `scripts/capture-matrix.sh`.
