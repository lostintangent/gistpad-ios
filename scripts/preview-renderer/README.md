# Offline Markdown preview

Preview ships a local WebKit document renderer, not the GistPad website. `scripts/preview-renderer` builds it from the sibling `gistpad.dev` checkout, next to this repository.

The native host supports iOS 27.2 and later. Its resource scheme, bridge and rendering do not require Duo-only APIs.

## Build

```sh
cd scripts/preview-renderer
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
```

The web repository and its installed dependencies must be present when rebuilding. The app does not need that repository, Node, a server or network access at runtime. Build output is checked in under the Swift package's `Resources/Web`. `provenance.json` records SHA-256 fingerprints of the web source. The build resolves symlinked web-source paths and fails unless both required source adapters run. Rebuild deliberately when the web dialect changes.

The build imports the original `remarkInlineSyntax`, `rehypeToc`, `Mermaid`, calculation logic and preview CSS. Standard plugin order matches `MarkdownPreview.tsx`. Native interaction components replace website UI, routing and task-text matching. A guarded source adapter replaces the calculator's `Function` call with a non-executable arithmetic parser. Comparison tests exercise the original and adapted calculator, including errors, formatting and assignments. The build fails if that upstream integration point changes. Mermaid is the web's component unchanged, with its default and dark themes. A UI-only alias supplies its dark-mode hook from the native appearance payload, and diagram text uses the system font.

HTML is sanitized before slug/TOC generation and task annotation. Scripts, forms, frames, event handlers and arbitrary styles cannot reach the page. CSP permits only bundled scripts, styles and fonts, with no eval, network connections, objects or frames. HTTPS images and raster data images are allowed, use no referrer and show an offline fallback on failure. Inline styles remain necessary for the original Mermaid SVG and TOC. Mermaid retains its original strict security mode.

## Native API

```swift
MarkdownPreviewView(markdown: markdown, fileID: fileID, generation: generation,
                    allowsTaskEdits: access.canEdit) { event in
    // Route links natively. Apply tasks through the document session and its undo manager.
}
```

Every actionable message includes the document identity and generation, and the host drops messages from an older generation. Tasks carry an NSRange-compatible UTF-16 range, the exact `[ ]` / `[x]` / `[X]` marker and its replacement. Source offsets come from the parsed task's position, not task text, so duplicate labels are unambiguous. The host checks the frame and origin, task ranges and markers, and link schemes. Everything else crossing the bridge is trusted, because both sides ship in one bundle. No credentials or auth/session objects enter WebKit.

Both `MarkdownPreviewView` and `EditorView` accept `comments: CommentHighlightConfiguration`, plus optional `onOpenCommentThreads` and `onLinkedCommentIDsChange` callbacks. Supply root-thread `CommentQuote` values from `Comments`, the selected root ID and the inline-visibility preference. Each surface reports its own verified IDs. Historical revisions must receive an empty configuration. Hiding idle annotations does not hide an explicitly selected verified quote.

Increment `revealRevision` to reveal the same selected root again after the reader scrolls away. Both modes resolve only the current verified quote. Ordinary updates with an unchanged selection/revision do not request another jump.

An optional `onAddComment: (String) -> Void` appends Add Comment to the native selection menu without replacing system actions. Edit passes the exact selected source slice. Preview uses an uncached deferred native menu element to pull the current rendered `Selection.toString()` only when the menu appears. The shared native eligibility check requires four trimmed UTF-16 units, but the callback receives the original whitespace and Unicode unchanged. Menu actions retain their document/generation snapshot and reject stale activations. Pass nil for contexts where comments cannot be created, including Daily, unpublished notes and historical revisions.

The shared native matcher is authoritative. Edit matches one exact source segment, including front matter for uniqueness, then excludes hidden front-matter ranges from its visible links. Preview catalogs individual HAST text nodes after sanitization, TOC and task annotation, excluding entire `pre`, `code` and `svg` subtrees just like the web. It never joins formatted nodes or maps rendered selections back to source. The host pulls the complete catalog with `callAsyncJavaScript`, so long nodes are not truncated or divided. A catalog from an older generation is discarded.

Native overlap partitioning retains every thread ID in each disjoint fragment. IDs travel to JavaScript as numbers. A Preview activation sends only its verified segment/range through a separate main-frame handler, and the native host resolves the complete ID list for the caller's thread chooser. The message stays small even for many overlapping threads. Authored HTML cannot create these annotations, which use private renderer-owned HAST node identities after sanitization.

Adjacent selected overlap fragments share one continuous rounded background on each line. Their thread targets remain separate, and backgrounds never bridge an unhighlighted gap or a line break.

Idle fills start at the saved accent mixed 50% over the actual opaque page, reducing only that mix when necessary to retain existing ink contrast. Selected fragments use the established accent fill/on-fill roles without adding an underline. Rounded fragments do not change text metrics. Preview also exposes keyboard activation and selected accessibility semantics. Edit places native shape layers behind the retained text canvas, using TextKit 2's exact range geometry. It deliberately does not apply UIKit's text-highlight attributes, which recolor glyphs even when their foreground override is omitted. Native blue selection remains intact. Edit appends View Comment through the modern multi-range edit-menu delegate without replacing system actions. Single-tap comment actions yield to native double-tap word selection. Quote annotations do not become link-style text items, which would override source ink and intercept editing gestures. Native Find and Writing Tools temporarily own their presentation. Annotation changes do not edit source or add Undo steps.

Selected Preview passages open enclosing disclosures and reveal enclosing spoilers, then scroll into view with `scrollIntoView`, which respects the root scroll-padding set from the native viewport insets. Matching starts after the host establishes its initial scroll origin, so that origin reset cannot undo a selected-quote jump. Annotation DOM updates preserve rendered selection endpoints inside their stable text-node wrappers. This is selection maintenance, not rendered-to-source mapping.

To see comments in the real note, launch a DEBUG build with `--fixture standard --open highlights`, adding `--mode preview` or `--mode edit` and `--sheet comments` as needed (see `docs/capture-matrix.md`). The fixture is in memory and never reads an account or publishes a comment. `CommentsUITests` covers posting and replying, selecting a thread from a Preview highlight, and the reading position holding still while Comments opens and closes.

On an Open Duo, XCUITest's app screenshot can capture the inactive folded display as a black image. Capture the actual Open display with `xcrun simctl io <simulator-id> screenshot --display=primary-1 <path>` and inspect those pixels instead. The native-hosted reveal regressions cover both the last-passage viewport and repeating the same selected quote after scrolling away.

`allowsTaskEdits` travels in the render request, so an access change rerenders the document. Pass the document's actual edit capability. Read-only checkboxes stay legible, expose disabled/read-only semantics and never emit edits. The native receiver drops task events that arrive after access is revoked.

The transparent WebKit host uses automatic native content insets, vertical bounce and the system's soft top/bottom edge effects. Its public SwiftUI wrapper measures the unobscured viewport with a noninteractive native marker while extending only the web view under container bars. The surrounding host must not ignore those safe areas first. Keyboard avoidance stays active. Comparing the marker's actual rectangle with the web view avoids counting a keyboard both as reduced height and as bottom padding. Only the missing inset is added when UIKit already supplies part or all of it.

The first rendered document waits for WebKit's initial CSS layout to settle, then positions the native scroll origin at the adjusted inset, keeping its first heading below the navigation bar. Later generations of that document retain the reading position. When native viewport insets change, the host preserves the scrolled content's distance from the safe reading edge, not just the document's first line. Native tracking and deceleration retain control of scrolling. Viewport messages set the root scroll-padding, so Contents anchors and focus scrolling respect the unobscured native viewport. This is scroll geometry, not duplicate document padding or a web gradient mask.

The host resolves semantic colors and text-style metrics from native traits and updates CSS variables separately from Markdown. Appearance changes do not reparse source or replace selection. Dynamic Type, Bold Text, light/dark and increased contrast follow the approved design direction. `Accent` derives personal-accent text/fill/selection roles once for native and preview consumers, using final quantized sRGB contrast against the resolved semantic surfaces. Text targets 4.5:1, or 7:1 with Increased Contrast. The stored profile hex is never changed by adaptation.

The containing workspace applies `.accent(savedHex:)` from Interface. Its public SwiftUI-to-UIKit trait bridge carries the same profile choice into native controls, caret/accessory colors and preview appearance. Missing values use sky, including when the preview is hosted on its own. Invalid values keep that fallback and are explained in Settings. The web page's fallback colors are only for standalone browser checks. `WKWebView` is intentionally isolated behind one representable to expose its local resource-scheme handler and validated message/frame boundary. SwiftUI owns the surrounding UI.

Reading prose and headings share semantic primary label ink. Code retains its four adaptive syntax colors. Calculator labels, default diagram edges and selected surfaces use the personal accent's readable roles, not decorative gradient stops. Page/surface/separator and prose-link colors remain native semantic values. Authored diagram colors and user content are not recolored.

All rendered headings use the native system sans-serif, matching body text. At Large, H1/H2/H3 retain the approved 34/25.5/21.25-point web-derived scale. At other categories, the native host adds the exact point growth of UIKit's Large Title/Title 2/Title 3 relative to each style at Large. The resolved sizes travel through the existing appearance variables instead of remaining fixed multiples of the scaled Body. This preserves the standard page while letting the heading/body hierarchy narrow naturally at accessibility sizes, without a cap or clamp. Headings prefer whole words, with emergency wrapping only for tokens wider than the column. H1 and H2 have a one-point semantic separator rule with 1rem of padding above it. Increased Contrast uses the shared stronger boundary role. No font downloads or source changes are involved.

The shared TOC transform retains its heading/link semantics inside a compact, initially closed Contents disclosure. Its SF label and primary-text, 44-point whole-row anchors remain keyboard accessible. Expanding Contents survives source generations without changing authored HTML disclosure states. Its block layout has no trailing margin, avoiding a doubled gap before the next heading. No outline is injected unless the note requests it. Inline prose links stay blue and underlined. Every alert kind retains its text label and gains a decorative symbol, rather than relying on color or unsafe inline CSS masks.

The page has one 20-point gutter (16 in panes at most 360 points wide), a 64ch maximum measure, 24 points above the first block and 40 below the last. Body uses the web prose's 1.75em leading and 1.25em paragraph margins. H2 starts a section with 3rem of space. H3 uses 2rem of leading space, and list items have 0.5em margins. The first block still starts at the page's single top inset.

Authored bullets and numbers match the web's `prose-neutral` / `prose-invert` palette from `@tailwindcss/typography` 0.5.20, with ordinary inherited weight, the web's 1.625em list inset and 0.375em item padding. Normal Light uses `#D4D4D4` bullets and `#737373` numbers. Normal Dark uses `#525252` bullets and `#A1A1A1` numbers. The separate `--gp-list-bullet` and `--gp-list-number` tokens preserve those intentionally soft bullets exactly, without contrast-derived adjustment. Increased Contrast replaces both with the stronger native gray at 7:1. Raw Edit uses the same exact normal bullet/number colors, keeping its existing enhanced muted ink for Increased Contrast.

Task-checkbox borders/checked fills retain `--gp-list-marker`: native secondary-label gray composited against the page, then adjusted toward native label ink only enough to reach 4.5:1 normally or 7:1 with Increased Contrast. Raw Edit's task brackets use `secondaryLabel`. Task text stays primary ink, checked boxes retain a contrasting page-colored checkmark, and targets stay at least 44 points. These roles remain independent of the personal accent and do not recolor secondary captions. Numbering, nesting, wrapping, task state and generated Contents are unchanged.

`PreviewFixtures.mangaReading` is a reading-list excerpt with a synthetic H2 section of numbered and nested bulleted lists, and `PreviewFixtures.listMarkers` is a short list for checking marker ink. Use them for renderer checks of list markers, rules and bullets.

Calculation results retain the original exact values and selection/copy exclusion, with accessible current/previous labels, semantic surfaces and tabular numerals. Tables retain authored alignment and native table semantics, with horizontal rules instead of boxes, vertical grids or zebra fills. Real `details`/`summary` disclosures have a stroked chevron, a 44-point row and keyboard/pressed/focus behavior. `try PreviewFixtures.readingPolish` loads a focused synthetic fixture covering these treatments, neutral and authored diagrams, all five alerts and a locally scrolling twelve-column table.

## Evidence

```sh
(cd scripts/preview-renderer && bun test && npm run typecheck && npm run build)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter PreviewTests
```

`bun test` covers task source ranges (including duplicate labels and raw HTML that tries to forge a task), comment overlap runs and the comment text catalog. The iOS package test loads the all-syntax fixture through the actual resource scheme. It checks that read-only checkboxes never emit edits, that an editable rerender toggles the exact `[x]` range of the clicked task, that Mermaid renders an SVG and that wikilinks reach native. A second test checks reading character and the top inset across viewport resizes.

The suite passes on iOS 27.0 iPhone 18 Pro and iOS 27.1 Duo. A successful DOM/bridge test does not certify a snapshot: inspect the exported pixels. The current window-hosted package runner produces black snapshot attachments despite passing rendering assertions, so those images are not visual evidence. Use the running app for new captures. Earlier unattached-view Duo snapshots were inspected and rendered correctly, but that test setup did not navigate reliably on iOS 27.0. Isolated renderer snapshots are not the app's folded/open screenshot matrix or Designer's sign-off. Physical-device performance, VoiceOver behavior and fold continuity remain hardware checks.

The comments inspector stays native and outside WebKit. Whiteboards, diagram/image enlargement and remote-image caching remain follow-up work. Mermaid follows the web engine's own limits. Selection-to-source mapping is not part of this bridge.
