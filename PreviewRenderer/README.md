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

The build imports the original `remarkInlineSyntax`, `rehypeToc`, `Mermaid`, calculation logic and preview CSS. Standard plugin order matches `MarkdownPreview.tsx`. Native interaction components replace website UI, routing and task-text matching. A guarded source adapter replaces the calculator's `Function` call with a non-executable arithmetic parser. Comparison tests exercise the original and adapted calculator, including errors, formatting and assignments. A second guarded adapter supplies Mermaid's neutral native theme and adds its resolved-color fingerprint to the original SVG cache key. The build fails if either upstream integration point changes. Authored Mermaid classes/styles are not rewritten. A UI-only alias supplies the dark-mode hook from the native appearance payload, so embedded/overridden traits cannot disagree with a browser media query. Translucent semantic strokes are composited on the actual node surface and checked against both the node and page for at least 3:1 contrast.

HTML is sanitized before slug/TOC generation and task annotation. Scripts, forms, frames, event handlers and arbitrary styles cannot reach the page. CSP permits only bundled scripts, styles and fonts, with no eval, network connections, objects or frames. HTTPS images and raster data images are allowed, use no referrer and show an offline fallback on failure. Inline styles remain necessary for the original Mermaid SVG and TOC. Mermaid retains its original strict security mode.

## Native API

```swift
MarkdownPreviewView(document: markdown, documentID: fileID, generation: generation,
                    allowsTaskEdits: access.canEdit) { event in
    // Route links natively. Apply tasks through the document session and its undo manager.
}
```

Every actionable message includes document identity and a decimal-string UInt64 generation. Tasks carry an NSRange-compatible UTF-16 range, the exact `[ ]` / `[x]` / `[X]` marker and its replacement. Call `edit.validate(in:documentID:generation:)` immediately before applying it. Source offsets come from the parsed task's position, not task text, so duplicate labels are unambiguous. The host validates frame/origin, message sizes, ranges, markers, generation and URL schemes. No credentials or auth/session objects enter WebKit.

`allowsTaskEdits` defaults to true for existing callers. Pass the document's actual edit capability. Access updates do not rerender Markdown or replace selection. Read-only checkboxes stay legible, expose disabled/read-only semantics and never emit edits. The native receiver explicitly discards and logs validated task events already in flight when access is revoked. The WebKit scroll view uses the system's soft bottom edge, matching the native note chrome.

The host resolves semantic colors and text-style metrics from native traits and updates CSS variables separately from Markdown. Appearance changes do not reparse source or replace selection. Dynamic Type, Bold Text, light/dark and increased contrast follow `docs/design-system.md`. The web page's fallback colors are only for standalone browser checks. `WKWebView` is intentionally isolated behind one representable to expose its local resource-scheme handler and validated message/frame boundary. SwiftUI owns the surrounding UI.

The shared TOC transform retains its heading/link semantics, presented as a labeled Contents navigation region with primary-text, 44-point whole-row anchors. Inline prose links stay blue and underlined. Every alert kind retains its text label and gains a decorative symbol, rather than relying on color or unsafe inline CSS masks.

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

The browser checks block every external request. The all-syntax check renders Mermaid, edits the second of two identically named tasks, exercises link/wikilink/spoiler actions and verifies CSP blocks eval. It also checks the quiet outline's targets and all five alert symbols. The focused reading check verifies exact result values/labels/surfaces, grid-free aligned tables, local scrolling and keyboard disclosure behavior across four themes and two text sizes. It checks node/arrow contrast and preserves an authored diagram style while native colors change. The iOS package test runs the same focused fixture through the actual resource scheme, applies four native themes at Large and AX3, checks text contrast and selection through appearance updates, records diagnostic snapshots and renders a 100K+ multilingual document. The view is hosted in a real test window for reliable resource navigation. Startup failures include page state, JavaScript/CSP diagnostics and navigation errors.

The suite passes on iOS 27.0 iPhone 18 Pro and iOS 27.1 Duo. A successful DOM/bridge test does not certify a snapshot: inspect the exported pixels. The current window-hosted package runner produces black snapshot attachments despite passing rendering assertions, so those images are not visual evidence. Use the running app for new captures. Earlier unattached-view Duo snapshots were inspected and rendered correctly, but that test setup did not navigate reliably on iOS 27.0. Isolated renderer snapshots are not the app's folded/open screenshot matrix or Designer's sign-off. Physical-device performance, VoiceOver behavior and fold continuity remain hardware checks.

Whiteboards and comment UI are outside v1 scope. Diagram/image enlargement and remote-image caching remain follow-up work. A render is bounded to two million UTF-16 code units, and Mermaid follows the web engine's own limits. Selection-to-source mapping is not part of this bridge.
