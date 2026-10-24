# Offline Markdown preview

`Packages/GistPadPreview` ships a local WebKit document renderer, not the GistPad website. `PreviewRenderer` builds it from the sibling `../../gistpad.dev` repository.

The native host supports iOS 27.1 and later. Its resource scheme, bridge and rendering do not require Duo-only APIs.

## Build

```sh
cd PreviewRenderer
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
```

The web repository and its installed dependencies must be present when rebuilding. The app does not need that repository, Node, a server or network access at runtime. Build output is checked in under the Swift package's `Resources/Web`. `provenance.json` records SHA-256 fingerprints of the web source. Rebuild deliberately when the web dialect changes.

The build imports the original `remarkInlineSyntax`, `rehypeToc`, `Mermaid`, calculation logic and preview CSS. Standard plugin order matches `MarkdownPreview.tsx`. Native interaction components replace website UI, routing and task-text matching. A guarded source adapter replaces the calculator's `Function` call with a non-executable arithmetic parser. Comparison tests exercise the original and adapted calculator, including errors, formatting and assignments. A second guarded adapter supplies Mermaid's native theme and adds its resolved-color fingerprint to the original SVG cache key. The build fails if either upstream integration point changes. Authored Mermaid classes/styles are not rewritten. A UI-only alias supplies the dark-mode hook from the native appearance payload, so embedded/overridden traits cannot disagree with a browser media query. Default nodes have modestly rounded rectangles, semantic secondary fill, primary-label SF text and a one-pixel separator-derived boundary. Other shapes and authored radii remain meaningful. Boundaries minimally mix toward the label ink until they reach 3:1 against both the node surface and page. Essential edges and arrowheads use the readable personal accent, also checked at 3:1.

HTML is sanitized before slug/TOC generation and task annotation. Scripts, forms, frames, event handlers and arbitrary styles cannot reach the page. CSP permits only bundled scripts, styles and fonts, with no eval, network connections, objects or frames. HTTPS images and raster data images are allowed, use no referrer and show an offline fallback on failure. Inline styles remain necessary for the original Mermaid SVG and TOC. Mermaid retains its original strict security mode.

## Native API

```swift
MarkdownPreviewView(document: markdown, documentID: fileID, generation: generation,
                    allowsTaskEdits: access.canEdit) { event in
    // Route links natively. Apply tasks through the document session and its undo manager.
}
```

Every actionable message includes document identity and a decimal-string UInt64 generation. Tasks carry an NSRange-compatible UTF-16 range, the exact `[ ]` / `[x]` / `[X]` marker and its replacement. Call `edit.validate(in:documentID:generation:)` immediately before applying it. Source offsets come from the parsed task's position, not task text, so duplicate labels are unambiguous. The host validates frame/origin, message sizes, ranges, markers, generation and URL schemes. No credentials or auth/session objects enter WebKit.

`allowsTaskEdits` defaults to true for existing callers. Pass the document's actual edit capability. Access updates do not rerender Markdown or replace selection. Read-only checkboxes stay legible, expose disabled/read-only semantics and never emit edits. The native receiver explicitly discards and logs validated task events already in flight when access is revoked.

The transparent WebKit host uses automatic native content insets, vertical bounce and the system's soft top/bottom edge effects. Its public SwiftUI wrapper measures the unobscured viewport with a noninteractive native marker while extending only the web view under container bars. The surrounding host must not ignore those safe areas first. Keyboard avoidance stays active. Comparing the marker's actual rectangle with the web view avoids counting a keyboard both as reduced height and as bottom padding. Only the missing inset is added when UIKit already supplies part or all of it.

The first rendered document waits for WebKit's initial CSS layout to settle, then positions the native scroll origin at the adjusted inset, keeping its first heading below the navigation bar. Later generations of that document retain the reading position. Small validated viewport messages set the root scroll-padding, so Contents anchors and focus scrolling respect the unobscured native viewport. This is scroll geometry, not duplicate document padding or a web gradient mask.

The host resolves semantic colors and text-style metrics from native traits and updates CSS variables separately from Markdown. Appearance changes do not reparse source or replace selection. Dynamic Type, Bold Text, light/dark and increased contrast follow the approved design direction. `GistPadAppearance` derives personal-accent text/fill/selection roles once for native and preview consumers, using final quantized sRGB contrast against the resolved semantic surfaces. Text targets 4.5:1, or 7:1 with Increased Contrast. The stored profile hex is never changed by adaptation.

The containing workspace applies `.personalAccent(savedHex:)` from Interface. Its public SwiftUI-to-UIKit trait bridge carries the same profile choice into native controls, caret/accessory colors and preview appearance. Missing values use sky, including when the preview is hosted on its own. Invalid values keep that fallback and are explained in Settings. The web page's fallback colors are only for standalone browser checks. `WKWebView` is intentionally isolated behind one representable to expose its local resource-scheme handler and validated message/frame boundary. SwiftUI owns the surrounding UI.

Reading prose and headings share semantic primary label ink. Code retains its four adaptive syntax colors. Calculator labels, default diagram edges and selected surfaces use the personal accent's readable roles, not decorative gradient stops. Page/surface/separator and prose-link colors remain native semantic values. Authored diagram colors and user content are not recolored.

All rendered headings use the native system sans-serif, matching body text. At Large, H1/H2/H3 retain the approved 34/25.5/21.25-point web-derived scale. At other categories, the native host adds the exact point growth of UIKit's Large Title/Title 2/Title 3 relative to each style at Large. The resolved sizes travel through the existing appearance variables instead of remaining fixed multiples of the scaled Body. This preserves the standard page while letting the heading/body hierarchy narrow naturally at accessibility sizes, without a cap or clamp. Headings prefer whole words, with emergency wrapping only for tokens wider than the column. H1 and H2 have a one-point semantic separator rule with 1rem of padding above it. Increased Contrast uses the shared stronger boundary role. No font downloads or source changes are involved.

The shared TOC transform retains its heading/link semantics inside a compact, initially closed Contents disclosure. Its SF label and primary-text, 44-point whole-row anchors remain keyboard accessible. Expanding Contents survives source generations without changing authored HTML disclosure states. Its block layout has no trailing margin, avoiding a doubled gap before the next heading. No outline is injected unless the note requests it. Inline prose links stay blue and underlined. Every alert kind retains its text label and gains a decorative symbol, rather than relying on color or unsafe inline CSS masks.

The page has one 20-point gutter (16 in panes at most 360 points wide), a 64ch maximum measure, 24 points above the first block and 40 below the last. Body uses the web prose's 1.75em leading and 1.25em paragraph margins. H2 starts a section with 3rem of space. H3 uses 2rem of leading space, and list items have 0.5em margins. The first block still starts at the page's single top inset.

Authored bullets and numbers match the web's `prose-neutral` / `prose-invert` palette from `@tailwindcss/typography` 0.5.20, with ordinary inherited weight, the web's 1.625em list inset and 0.375em item padding. Normal Light uses `#D4D4D4` bullets and `#737373` numbers. Normal Dark uses `#525252` bullets and `#A1A1A1` numbers. The separate `--gp-list-bullet` and `--gp-list-number` tokens preserve those intentionally soft bullets exactly, without contrast-derived adjustment. Increased Contrast replaces both with the stronger native gray at 7:1. Raw Edit uses the same exact normal bullet/number colors, keeping its existing enhanced muted ink for Increased Contrast.

Task-checkbox borders/checked fills retain `--gp-list-marker`: native secondary-label gray composited against the page, then adjusted toward native label ink only enough to reach 4.5:1 normally or 7:1 with Increased Contrast. Raw Edit's task brackets remain `InterfaceTheme.syntaxMuted`. Task text stays primary ink, checked boxes retain a contrasting page-colored checkmark, and targets stay at least 44 points. These roles remain independent of the personal accent and do not recolor secondary captions. Numbering, nesting, wrapping, task state and generated Contents are unchanged.

`--capture-manga-fixture` opens the production note/preview with a local reading-list excerpt transcribed from the user's reference image. It does not read an account or the live Manga gist. The fixture includes a clearly marked synthetic H2 section with numbered/nested bulleted lists. `--capture-state markers` positions the first list below the native bar, `rules` positions the synthetic H2 section and `bullets` positions the synthetic unordered list. Positioning failures appear in capture readiness. Capture Light/Dark at Large and AX3. `PreviewFixtures.mangaReading` exposes the same source for renderer checks.

`--capture-screen note --capture-marker-fixture` opens a short synthetic list in the real note surface. Add `--capture-source` to start in Edit, `--capture-accent` to verify accent independence and `--capture-increased-contrast` to apply a native window trait override only in this debug fixture. `MutedMarkerUITests` captures both modes in Light/Dark and normal/increased contrast with yellow and magenta saved accents, without changing simulator system preferences.

Calculation results retain the original exact values and selection/copy exclusion, with accessible current/previous labels, semantic surfaces and tabular numerals. Tables retain authored alignment and native table semantics, with horizontal rules instead of boxes, vertical grids or zebra fills. Real `details`/`summary` disclosures have a stroked chevron, a 44-point row and keyboard/pressed/focus behavior. `try PreviewFixtures.readingPolish` loads a focused synthetic fixture covering these treatments, neutral and authored diagrams, all five alerts and a locally scrolling twelve-column table.

## Evidence

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/GistPadPreview

# From the repository root, in a separate terminal:
python3 -m http.server 4179 --bind 127.0.0.1 \
  --directory Packages/GistPadPreview/Sources/GistPadPreview/Resources
playwright-cli -s=gistpad-preview open http://127.0.0.1:4179/Web/index.html
playwright-cli -s=gistpad-preview run-code --filename PreviewRenderer/tests/browser-check.js
playwright-cli -s=gistpad-preview run-code --filename PreviewRenderer/tests/reading-check.js
```

The browser checks block every external request. The all-syntax check renders Mermaid, edits the second of two identically named tasks, exercises link/wikilink/spoiler actions and verifies CSP blocks eval. It also checks the quiet outline's targets and all five alert symbols. The focused reading check verifies exact result values/labels/surfaces, grid-free aligned tables, local scrolling and keyboard disclosure behavior across four themes and three supplied typography payloads. It checks node/arrow contrast and preserves an authored diagram style while native colors change. The iOS package test runs the same focused fixture through the actual resource scheme, applies four native themes at Large, AX3 and AX5, checks text contrast and selection through appearance updates, records diagnostic snapshots and renders a 100K+ multilingual document. Native heading metrics are checked against UIKit at every text category. A shared heading-wrapping fixture checks every word of `The shape of a notebook` at 382- and 834-point viewports, plus emergency wrapping of a genuinely oversized token. Those line-box assertions cover H1/H2/H3 in actual WebKit at Large/AX3/AX5, rather than treating absence of page overflow as proof of whole words. The view is hosted in a real test window for reliable resource navigation. Startup failures include page state, JavaScript/CSP diagnostics and navigation errors.

`GistPadTests/PreviewKeyboardHostTests` uses the app's real keyboard and a 120-point native shelf. It checks usable preview height, in-document task focus, native scrolling to the final task and recovery after keyboard dismissal. A package-hosted text field is not an equivalent keyboard test because its keyboard layout guide may never reflect a real keyboard.

The suite passes on iOS 27.0 iPhone 18 Pro and iOS 27.1 Duo. A successful DOM/bridge test does not certify a snapshot: inspect the exported pixels. The current window-hosted package runner produces black snapshot attachments despite passing rendering assertions, so those images are not visual evidence. Use the running app for new captures. Earlier unattached-view Duo snapshots were inspected and rendered correctly, but that test setup did not navigate reliably on iOS 27.0. Isolated renderer snapshots are not the app's folded/open screenshot matrix or Designer's sign-off. Physical-device performance, VoiceOver behavior and fold continuity remain hardware checks.

Whiteboards and comment UI are outside v1 scope. Diagram/image enlargement and remote-image caching remain follow-up work. A render is bounded to two million UTF-16 code units, and Mermaid follows the web engine's own limits. Selection-to-source mapping is not part of this bridge.
