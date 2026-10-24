# GistPad Native design system

Version 1, October 23, 2026. Owner: Designer. Applies to native UI, the TextKit source editor, the bundled WebKit preview, and later system surfaces.

**A quiet notebook with a precise Markdown engine.** Content is stable, controls are recognizably iOS, and every action tells the truth about its effect. Use system components before custom styling. Modern means the best supported tool for the job, not replacing a reliable text engine merely because a newer wrapper exists.

This is the implementation specification and review gate, not a claim that the current spike passes it. The app is personal, installed directly with the user's paid developer account. No marketing onboarding, App Store work, or subscription UI.

## 1. Non-negotiable product rules

- Existing notes open rendered. New notes open in source. An interrupted edit resumes at its selection.
- Cover display: Library or one document. Open inner display: Library + document. Deliberate Focus: source + preview, with Library hidden. Never three squeezed columns.
- One document session and native text surface survive presentation changes. Folding never saves, publishes, changes mode, accepts a proposal, or resets undo.
- Local drafts and GitHub publication are different states. Autosave off never publishes on background.
- Today contains the user's current dated note and template. **No Earlier days, task carryover, automatic journal text, or large-gist Git fallback.** A truncated response warns and blocks unsafe writes.
- Tags apply to gists, not individual files or days. Secret gists and uploaded images are readable by URL.
- Writing Tools is the v1 intelligence surface. Later generated edits remain separate proposals until Apply. No permanent chatbot.

The accepted recommendation governs scope. Earlier concept sketches are directional, not production geometry or an exception to these rules.

## 2. Color: one set of roles, four appearances

### System roles

Use semantic colors, resolved against the **containing view's traits**. Never copy sample system RGB values into assets or CSS. Colors can change between OS releases, appearances, elevated presentations, and accessibility settings. [1, 2]

| Token | Native source | Preview CSS variable | Use |
| --- | --- | --- | --- |
| `page` | `UIColor.systemBackground` | `--gp-page` | Editor and reading canvas, including the WebKit under-page color |
| `surface` | `UIColor.secondarySystemBackground` | `--gp-surface` | Code blocks and quiet grouped content |
| `surfaceRaised` | `UIColor.tertiarySystemBackground` | `--gp-surface-raised` | Only a genuine nested content surface |
| `text` | `UIColor.label` | `--gp-text` | All prose, headings, task labels |
| `textSecondary` | `UIColor.secondaryLabel` | `--gp-text-secondary` | Supporting metadata, not essential source syntax |
| `separator` | `UIColor.separator` | `--gp-separator` | Nonessential dividers |
| `boundary` | `UIColor.opaqueSeparator` | `--gp-boundary` | Visible content boundaries, checked at actual contrast |
| `link` | `UIColor.link` | `--gp-link` | External links and wikilinks, with a non-color affordance |
| `error` | `UIColor.systemRed` | `--gp-error` | Errors, with a symbol and explanation |
| `success` | `UIColor.systemGreen` | `--gp-success` | Explicit success, never the only status signal |

System navigation/list materials retain their standard styles. `surface` is not an instruction to put every row inside a card. Do not use `tertiaryLabel`, opacity, or separator colors for necessary small text.

### Custom roles

These are exact sRGB assets, with light, dark, light increased-contrast, and dark increased-contrast variants. Use these names in a shared native theme and the appearance payload. SwiftUI uses the native asset/theme, not a separate set of inline RGB literals.

| Token / CSS suffix | Light | Dark | Light increased | Dark increased |
| --- | --- | --- | --- | --- |
| `accentText` / `accent-text` | `#765800` | `#F3D26A` | `#573E00` | `#FFE899` |
| `accentFill` / `accent-fill` | `#EBC85A` | `#E9C75A` | `#F0C84B` | `#F7D45B` |
| `onAccent` / `on-accent` | `#231B08` | `#231B08` | `#151100` | `#151100` |
| `selectedSurface` / `selected-surface` | `#F8EFCC` | `#3D351C` | `#F4E2A3` | `#514211` |
| `syntaxMuted` / `syntax-muted` | `#68645C` | `#BAB5AA` | `#4F4A3E` | `#E1DCCF` |
| `syntaxCode` / `syntax-code` | `#4B5B5B` | `#C8D4D2` | `#283F3F` | `#E2EFEB` |

Prefix each CSS suffix with `--gp-`. `selectedSurface` uses `text` as its foreground and a selection trait/checkmark as appropriate. It is a row/anchor highlight, **not** the OS text-selection color.

Use `accentText` for small warm actions and task markers. Use `accentFill` with `onAccent` for an opaque custom primary control only. System prominent buttons own their foreground/material adaptation. Do not put white text on pale yellow, apply the fill as a global text tint, or paint every toolbar item yellow. Links stay system link blue, visually distinct from a warm action.

The custom text roles above clear 4.5:1 against reference light canvases `#FFFFFF`/`#F2F2F7` and dark canvases `#000000`/`#1C1C1E`. The lowest measured normal-mode text ratio is 5.28:1, increased-mode 7.90:1. `onAccent` against its fill exceeds 10:1 in all variants. Those reference backgrounds are **test inputs, not a definition of system colors**. Measure final resolved text/background pairs, selection surfaces, actual materials, and diagram labels on the shipping OS. Never assume these reference checks certify the whole screen.

User-defined tag colors stay compatible with the web. Show the tag name. Use a color swatch plus semantic text instead of forcing unreadable text onto an arbitrary fill. Chosen tags also have a checkmark. A tag's color is not an error or sync status.

## 3. Typography and Dynamic Type

Use SF through system font APIs, with language fallback. No bundled system fonts, fixed-size UI typography, condensed prose, manual tracking on body text, or all-uppercase labels needed to understand the product. [3]

| Role | Native text style | Treatment at default Large |
| --- | --- | --- |
| Screen title | System navigation title | Let navigation adapt size and placement |
| Document H1 | `.title` / `UIFont.TextStyle.title1` | Bold, approximately 28 pt |
| H2 | `.title2` | Semibold, approximately 22 pt |
| H3 | `.title3` | Semibold, approximately 20 pt |
| H4-H6 / section heading | `.headline` | Semibold, approximately 17 pt, preserve semantic heading levels |
| Prose / source / task | `.body` | Regular, approximately 17 pt |
| Library title | `.headline` | Default semibold, allow two lines then a detail route |
| Secondary metadata | `.subheadline` or `.footnote` | Not smaller merely to preserve a tight row |
| Code | Monospaced system font at scaled body size | Regular, no `.88em` reduction |
| Status / footnotes | `.footnote` | Approximately 13 pt, scales, remains readable |

Point sizes are reference values only. Native style APIs determine actual size. All labels wrap/grow at large categories. Required actions must not truncate to identical labels. Source headings stay body-sized semibold, not the large rendered heading sizes.

For UIKit, resolve `UIFont.preferredFont(forTextStyle:compatibleWith:)` using the current view traits and update attributed spans when those traits change. Use `UIFontMetrics` for a custom monospaced base. Do not double-scale a font that is already preferred/scaled. Attribute refresh must not change characters, marked text, undo, selection, or the current reading anchor. Defer restyling while composition or Writing Tools is active, then apply current traits safely. [4, 5]

### Shared preview appearance contract

**The host is the authority for Dynamic Type and appearance.** Resolve semantic colors and preferred font metrics in native code, then update the page's CSS variables in one transaction. The appearance update is presentation data, separate from document identity and draft generation. It must not reload the web view, replace Markdown, or erase selection/scroll.

The payload needs:

- Appearance and contrast, plus resolved sRGB colors for the roles in section 2.
- Preferred point sizes and native line heights for body, title1/title2/title3, headline, and footnote, plus the scaled monospaced body size.
- Bold Text state and layout direction when relevant to typography. Content direction remains determined by the content, not forced from the app language.

CSS metric names: `--gp-body-size`, `--gp-body-line-height`, `--gp-title1-size`, `--gp-title1-line-height`, `--gp-title2-size`, `--gp-title2-line-height`, `--gp-title3-size`, `--gp-title3-line-height`, `--gp-headline-size`, `--gp-headline-line-height`, `--gp-footnote-size`, `--gp-footnote-line-height`, `--gp-code-size`.

The preview's existing transport names remain stable: `background` -> `--gp-page`, `foreground` -> `--gp-text`, `secondaryForeground` -> `--gp-text-secondary`, `link` -> `--gp-link`, `separator` -> `--gp-separator`, `secondaryBackground` -> `--gp-surface`, `accentText` -> `--gp-accent-text`, `accentBackground` -> `--gp-selected-surface`. Retain `bodyFontSize` and `increasedContrast`, and add the preferred text-style metrics when integrating the complete appearance theme. `accentBackground` means a selected content surface, not the opaque primary-button fill.

A viewport with `width=device-width, initial-scale=1` makes host point-size values suitable as CSS pixels at the normal scale. Preserve pinch zoom. Use `font-family: -apple-system, BlinkMacSystemFont, sans-serif`, not a screenshot of text. Once native point sizes are injected, do not also apply an independent accessibility multiplier or the `-apple-system-body` font shorthand. Keep `-webkit-text-size-adjust: 100%` so the same scale is not applied twice.

CSS `prefers-color-scheme`/`prefers-contrast` and `font: -apple-system-body` can be a documented standalone-browser fallback, not the source of truth for the embedded app. The bridge's exact typed transport belongs to Renderer. Missing/invalid appearance must retain a legible last valid theme and surface a diagnostic, not silently render unreadable text.

## 4. Space, shape, and adaptive composition

Use system margins, row styles, sheets, popovers, and toolbars first. The scale below is for custom **content**, not a new chrome system.

| Token | Points | Use |
| --- | --- | --- |
| `space1` | 4 | Tight related details |
| `space2` | 8 | Symbol/label gap, inline content |
| `space3` | 12 | Related rows, compact content inset |
| `space4` | 16 | Standard content group gap |
| `space5` | 20 | Compact document side inset |
| `space6` | 24 | Document top/group spacing |
| `space8` | 32 | Larger content separation |
| `space10` | 40 | Breathing room at document end |

Document side inset starts at 20 pt in compact content and 28-32 pt when there is room. Respect the system's asymmetric safe area on Duo; never add a second manual toolbar gutter. Bottom inset accommodates the keyboard, safe area, and visible accessory, with at least one comfortable line of end space. Prefer container-relative margins rather than a device-width switch.

Custom content corner radii: 6 pt for inline code, 12 pt for a code/alert container. Let system buttons, tags/pickers, sheets, and widgets choose appropriate adaptive shapes. No universal 24-pt card wrapper, border on every paragraph, or fake phone frame.

Custom controls target at least 44 x 44 pt, including preview task targets. A 20-24 pt visible checkbox can have a larger nonoverlapping hit region. Grow rows rather than overlapping two adjacent tasks' tap targets. At accessibility sizes, stack metadata below the title and collapse companions before shrinking type. [6]

Navigation follows size classes and usable container bounds, not a device model or orientation guess. Use native split navigation for Library + document. Focus uses a navigation container around the two content surfaces, not navigation nested inside an arrangement. Let supported arrangements/reserved regions keep content reachable. Approximately 320 useful points per pane at default type is a hypothesis to validate, not a hard-coded Duo breakpoint. [7]

## 5. Materials and native controls

Liquid Glass belongs to **navigation and controls**, not the document. System navigation, toolbars, sheets, search, menus, and share sheets get modern platform treatment. Use their semantic placements, grouping, visibility priorities, and overflow behavior. Supply title + SF Symbol even if only the symbol is currently visible. [7, 8]

Reading and source are opaque `page` canvases. Code/alerts use content surfaces, not glass. A translucent panel behind every list row, tag, and paragraph is a rejection. Never hand-render blur/highlight edges to imitate system glass.

Reduce Transparency, Increase Contrast, Reduce Motion, and Bold Text must propagate through the native controls and WebKit presentation. Do not defeat them with a permanently translucent custom bar or pale placeholder text.

| Action | SF Symbol starting point | Semantics |
| --- | --- | --- |
| New gist / Edit | `square.and.pencil` | Different accessible titles in each context |
| Today | `calendar` | Date note, not weather |
| Source | `text.alignleft` | Markdown editing mode |
| Preview | `doc.richtext` | Rendered note |
| Focus | `rectangle.split.2x1` | Deliberate source/preview comparison |
| Tags | `tag` | Gist-level tags |
| Share | `square.and.arrow.up` | Native share flow |
| Pin / Star / Archive | `pin`, `star`, `archivebox` | Preserve their distinct meanings |
| Offline / Error | `wifi.slash`, `exclamationmark.circle` | Always paired with useful text |

Use system symbol weight/scale matched to adjacent text. Confirm each symbol in the installed SDK. No emoji as an unlabeled action, generic sparkle as a mode, or ellipsis for a menu other than system overflow. User emoji in note titles remains content.

## 6. Source syntax theme

The editor is Markdown source, not a lossy rich-text conversion. It should be quieter than a code IDE.

| Source element | Style |
| --- | --- |
| Ordinary prose | Body regular, `text` |
| Heading text | Body semibold, `text`; preserve all source characters |
| Heading/list/emphasis/fence punctuation | `syntaxMuted`, same readable size |
| Unchecked task marker | `accentText`, same size; never changes by decoration alone |
| Checked marker | `syntaxMuted`; do not make the task unreadable |
| Inline/fenced code | Monospaced scaled body, `syntaxCode`; optional `surface` block background |
| Link label / wikilink | `link`; source delimiters remain visible |
| URL destination | `syntaxMuted`, no hide/replace without an explicit source view |
| Frontmatter | Monospaced scaled body, `syntaxMuted`; explicit collapse affordance only |
| Selection, caret, marked text | Native system behavior, no custom purple selection |
| Proposed diff | Add/remove label and `+`/`-` or equivalent, not red/green alone |

Do not use opacity-faded entire code blocks, teal headings, a rainbow of language tokens by default, giant source headings, or an active-line highlight that competes with selection. Syntax changes must be pure attributes. No rewriting smart quotes, invisible delimiter removal, or automatic code formatting on appearance changes.

System Writing Tools exclude code/frontmatter through the supported integration. Highlighting and sync replacement must not interrupt Writing Tools or active IME composition. The inability to demonstrate that is an interaction blocker, not a typography compromise.

## 7. Rendered reading typography

The preview is a document, not a website inside a card. It matches the editor's semantic colors and native type scale, while preserving the web app's Markdown dialect.

| Element | Reading rule |
| --- | --- |
| Measure | Target `64ch`, centered only when there is surplus room; never narrow the cover unnecessarily |
| Body | Scaled body size; line height `max(1.5 * bodySize, nativeBodyLineHeight)` |
| First block | No artificial top margin; document has one content inset |
| Paragraph | 0 above, `0.85em` below |
| H1-H3 | Resolved native heading size/line height; bottom gap `0.55em`, top gap `1.25em` except first block |
| Heading decoration | No automatic underlining rule below every H1/H2 |
| Lists | Logical start indent, generous enough for marker; `0.35em` between items |
| Tasks | Native-looking checked/unchecked state, 44-pt usable target, visible pending/error state after a rejected edit |
| Links | System link color plus underline or a distinct linked-label treatment; no hover-only affordance |
| Table of contents | A quiet document outline on `surface`, headed Contents in the scaled headline style. Primary-text anchor rows, modest hierarchy indentation, no persistent underline, and a 44-pt whole-row target with visible pressed/focus states. Preserve anchor/link semantics and a labeled navigation landmark. This grouped navigation treatment is distinct from inline prose links, which remain link blue |
| Quote | 3-pt logical-start rule, 16-pt content inset; prose remains primary text, not low-contrast italic |
| Inline code | Body-size monospace, `surface`, 2-4 pt horizontal padding; no synthetic backticks |
| Fenced code | Body-size monospace, `surface`, 12-16 pt inset; preserve whitespace and allow horizontal scroll within the block |
| Tables | Scroll within their block when needed; cells remain legible, not shrunk to fit; semantics retained |
| Alerts | Kind label + symbol + boundary. Color supplements the meaning. Match shared roles in every contrast mode |
| Footnotes | Scaled footnote style, discoverable backlinks, no 0.8-em unreadable reduction |
| Diagrams/images | Fit available width, preserve aspect ratio, meaningful alternative text; explicit enlargement if needed |
| Empty/error content | Native-state treatment with an explanation and a real action, not a blank document |

Use logical CSS properties for RTL, with content-aware direction for mixed-script paragraphs. Isolate code direction where necessary without forcing the whole note LTR. No clipped diacritics or line boxes at large size. Do not assume a fixed `line-height` suits every script.

Remove browser tells without removing accessibility: no hover-only copy/link buttons, purple selection override, pointer-hand styling as the primary cue, default tap-flash, two nested page scroll views, overscroll glow, or web-wide horizontal panning. The WebKit host owns one document scroll surface and suppresses the requested preview rubber-band effect; this does not require disabling normal native list/editor scrolling. Block-level table/code scrolling still works.

Preserve native text selection, context menus, VoiceOver headings/links/tasks, keyboard focus outlines, and pinch zoom. Do not blanket `user-select: none`, disable all callouts, remove focus indication, or cancel every touch. A task target is an actual labeled interactive control, not a clickable paragraph.

Updating theme should modify CSS variables only. Re-rendering a document is a separate event with a source generation. Test live dark/contrast/type changes while selecting text and while source edits arrive.

## 8. Motion, haptics, and state language

Prefer system transitions. Custom motion exists only to explain a user action, follows its gesture, remains interruptible, and honors Reduce Motion. No page curl, folding parallax, bouncing save badges, rainbow thinking text, or repeated entrance animations. [9]

| Event | Visual / tactile feedback |
| --- | --- |
| Check a task | Keep row in place; one short state transition; at most a light selection response after local commit |
| Tag/collection selection | System selection behavior; no second app-generated haptic if the control already supplies it |
| Manual Save confirmed | Quiet status change. A success haptic is optional only for deliberate manual completion |
| Debounced autosave / background refresh | No haptic, toast, or sound |
| Action failed | Persistent useful error + Retry. Optional error response for a direct failed action, never a repeating alert |
| Archive | System row removal, Undo, no celebratory animation |
| Fold / resize | System layout adaptation, no app haptic or meaning change |
| AI Apply | One undoable local edit; no automatic publish or success claim about model correctness |

Use SwiftUI `sensoryFeedback` where appropriate, with state that represents the **committed outcome**, not the initial tap. No haptic for every typed character. Keep feedback optional and never essential to understanding the result. Simulator screenshots cannot prove tactile quality. [10, 11]

Approved save language:

| Real condition | Text |
| --- | --- |
| Durable local write, no confirmed matching GitHub version | Saved on this iPhone |
| Cloud request in progress | Saving to GitHub |
| Server accepted the current version | Saved to GitHub |
| Publication failed, local copy safe | Saved on this iPhone. Couldn't save to GitHub. |
| Local write failed | Couldn't save on this iPhone. Keep the editor open. |
| Changed remotely | This note changed elsewhere. |
| No persistence in an engineering fixture | In-memory fixture. Not saved. |

Do not call queued or in-memory data Saved. Preserve the failed operation and give a recovery action. Status is accessible text, not just a colored dot. Errors remain long enough to act, not solely in an expiring toast.

## 9. Review gate for every UI surface

**No production UI task closes without Designer sign-off on actual Duo simulator evidence.** A polished SVG, passing build, stock component, or Light-mode screenshot alone is not sign-off. Award-caliber is the quality ambition, not a claim of an Apple award.

For each implemented surface, supply eight captures from the same build and synthetic fixture:

| Duo presentation | Light / Large | Dark / Large | Light / AX3 | Dark / AX3 |
| --- | --- | --- | --- | --- |
| Cover display | Required | Required | Required | Required |
| Fully open inner display | Required | Required | Required | Required |

Large means the default Dynamic Type category, not a manually set 17-pt screenshot font. AX3 means SwiftUI `.accessibility3` / UIKit `.accessibilityExtraLarge`. Include the real keyboard in editing/capture evidence. Show relevant sheets, errors, and empty states for that task, not only the happy-path parent view. Name build, device/runtime, pose, appearance, contrast, type category, and state with the evidence. Attach images to the channel handoff rather than sharing image files as artifacts.

Also inspect light/dark Increase Contrast, Reduce Transparency, Reduce Motion, Bold Text, RTL/mixed-script text, and AX5 reachability. For a critical content/action boundary, retain contrast measurements using final resolved colors. A new generic component can reuse previous evidence only for unchanged internals, not to skip its new context.

### Short checklist

- [ ] The screen has one obvious purpose, with native navigation and consistent hierarchy.
- [ ] Titles, metadata, actions, content margins, and SF Symbols use the tokens above.
- [ ] Light, dark, increased contrast, and large type remain legible without clipped or hidden actions.
- [ ] Glass is limited to native controls/navigation, with no web/card chrome around prose.
- [ ] Cover/open layouts use available space and avoid active fold/camera regions.
- [ ] Task/action targets are comfortably tappable, labeled, and not color-only.
- [ ] Empty, loading, offline, failed, read-only, and permission states relevant to the surface have a truthful next action.
- [ ] Local-save/cloud-save/pending labels match real persistence, with no destructive surprise.
- [ ] VoiceOver order/focus, keyboard access, selection, and dismissal work in the actual UI.
- [ ] Editing, IME, undo, selection, scroll anchor, and presented state survive relevant transitions.
- [ ] Motion and feedback are purposeful, optional, and tested beyond a still image.
- [ ] Screenshots/interaction evidence are recorded, and Designer explicitly signs off or lists blockers.

Continuity requires a short recording or observed sequence: type/select, resize/fold, continue, undo. VoiceOver needs actual traversal. Performance needs measured frame/input behavior on the target hardware. Haptics require a device. Mark those **unverified** until observed rather than implying a simulator still proves them.

Review outcomes: **Approved**, **Approved for a named spike only**, or **Changes required**. A spike-only approval does not carry into v1. Diagnostics stay explicitly marked, are reachable without dominating the notebook, and must be removed from production surfaces before final approval.

## Primary references

1. [HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color)
2. [`UIColor.resolvedColor(with:)`](https://developer.apple.com/documentation/uikit/uicolor/resolvedcolor(with:))
3. [HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
4. [`UIFont.preferredFont(forTextStyle:compatibleWith:)`](https://developer.apple.com/documentation/uikit/uifont/preferredfont(forTextStyle:compatibleWith:))
5. [`UIFontMetrics`](https://developer.apple.com/documentation/uikit/uifontmetrics)
6. [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
7. [HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo) and [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
8. [HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
9. [HIG: Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
10. [HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
11. [`sensoryFeedback(_:trigger:)`](https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:))
