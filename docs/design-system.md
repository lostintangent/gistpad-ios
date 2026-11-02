# GistPad Native design system

Owner: Designer. This document owns visual tokens, native/rendered presentation and evidence requirements. [design-direction.md](design-direction.md) owns journeys, state, permissions and saving. Specifications are not claims that every surface ships or passes review.

## 1. Identity and platform

Target iOS 27.2+, installed directly with the user's developer account. No marketing onboarding, subscription UI or App Store work. Use supported native components before custom styling. A reliable TextKit editor is not replaced merely because a newer wrapper exists.

Keep the original `gistpad.dev/public/icon.svg` artwork: blue gradient spine, pale outlined cover, coral/amber/teal tabs, strokes, proportions and shadow. System appearance variants may adapt packaging, not redesign the master. Empty/first-run illustrations can use that original art at 48-64 pt, never fake per-note covers or error-state decoration.

Liquid Glass belongs to navigation, menus and controls. The native source/reading backing stays opaque. Transparent WebKit/HTML can reveal that backing beneath real system chrome. No glass paragraphs/cards, custom blur imitation, painted scroll-edge gradients or glass-on-glass. [Materials][materials], [Liquid Glass adoption][adoption].

## 2. Color and contrast

Resolve semantic colors against the containing view's actual traits. Do not hard-code example system RGB values into assets/CSS. Use shared native/Preview roles, updating appearance without changing source, selection, scroll or Undo. [Color][color], [Resolved colors][resolved].

| Role | Source / purpose |
| --- | --- |
| Page | `systemBackground`, opaque document backing |
| Content surface | `secondarySystemBackground`; tertiary only for genuine nesting |
| Prose ink | Shared exact assets: Light `#1E293B`, Dark `#E2E8F0`, Light Increased `#0F172A`, Dark Increased `#F8FAFC` |
| Metadata | Row date uses the system `.secondary` label role, which the system adapts for Increased Contrast. This is the user-requested muted exception to the normal-text contrast targets, gated by a visible darkening under Increased Contrast. It never stacks opacity on top of the role |
| Separators / boundaries | Semantic separator / opaque separator; required visible affordances measured at 3:1 |
| Links | Semantic link role plus underline or another explicit non-color affordance |
| Error / completion | System red / fixed system green, with meaning also expressed through symbols/text |
| Library selection | Native neutral selected surface and traits. Never personal tint or OS text-selection color |

Normal content text targets 4.5:1, Increased Contrast 7:1, against actual composited selected/unselected surfaces. Required nontext affordances target 3:1. Use WCAG relative luminance, not HSB brightness. System materials own their foreground adaptation; reference flat colors do not certify rendered glass.

### Personal content, neutral controls

Preserve a valid saved `accentColor`, including yellow. Missing values use GistPad sky `#0EA5E9`. Invalid data uses a legible native fallback and explicit Settings explanation, never silent metadata repair. The web preference/key remains authoritative; native does not invent a separate theme or rewrite the stored color for contrast.

Personal accent is limited to approved Today widget date/incomplete progress/in-content invitations, the preference swatch and comment annotations. The Today rail glyph/badge, ordinary progress/pins, Library selection and document list/task markers stay neutral. Completion uses fixed green; overdue unfinished counts can use contrast-safe amber. Tags keep their own saved colors.

| Derived role | Rule in each of Light, Dark and their Increased Contrast appearances |
| --- | --- |
| Accent text | Smallest mix toward black in Light or white in Dark meeting the text target on its actual opaque surfaces |
| Accent fill + on-fill | Prefer saved opaque fill. Choose black/white ink by greater contrast; minimally adjust fill only if needed to reach the text target |
| Selected content surface | Restrained content tint with measured ink contrast. Not Library selection, chrome tint or native blue text selection |
| Idle comment fill | Begin at 50% saved accent over page, reduce if needed for existing ink contrast |

Enabled chrome uses native primary adaptive monochrome foreground, not reduced opacity or personal tint: navigation, mode controls, menus, sheets, Tags checks, keyboard tools, Intelligence, Photos and recovery. Native disabled/prominent roles still communicate hierarchy. Keep destructive red, native switch defaults, semantic links and standard blue caret/selection. Never apply global tint/foreground that also recolors content or input.

Non-destructive swipe actions use explicit `UIColor.darkGray` with native white text/glyphs, nominally 7.46:1. Verify actual on-fill pixels in both appearances and Increased Contrast. Delete remains native destructive red. Archive is not destructive.

### Tag labels

Use scaled Footnote medium, 8-pt horizontal/4-pt vertical padding and 8-pt corners. Fill the label with the exact saved tag color at full opacity. Ink is black or white, whichever has higher contrast, so every fill reaches at least 4.58:1 and passes 4.5:1. A missing color uses the neutral system fill with primary text. No internal dot, tinted overlay, arbitrary colored text or whole-label opacity. Keep saved white and black exact, with their own edge against the surface.

At standard type a row's tags stay on one line: up to two names, truncating the first only when one won't fit, plus a truthful `+N` in plain secondary text, never a chip. Ordinary rows wrap/grow at AX. Use 6-pt gaps between tags. Metadata labels are not nested controls. Picker rows instead show one standalone swatch on an untinted row, full name and separate neutral selection check. Use an own-hue hairline only where needed, neutral gray for white; no universal black outline. Increased Contrast strengthens necessary boundaries. Measure final text/fill with white, black, yellow, saturated and similar hues.

## 3. Typography and geometry

Use SF through native style APIs and language fallback for interface, prose and rendered headings. Widget day numerals use system Rounded, about 44 pt at Large where space allows, scaling with Large Title. Code uses scaled system monospace. No bundled/private font names, New York headings, body tracking, condensed prose or fixed accessibility caps. Source headings remain body-sized bold. [Typography][type], [Preferred fonts][font], [Font metrics][metrics].

| Content metric | Standard Large reference |
| --- | --- |
| Spacing scale | 4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 pt; custom content only, not replacement system chrome |
| Document measure | One 20-pt gutter per side, 16 pt in a narrow Split pane; cap useful measure at 64ch. Never add both native and CSS gutters |
| Page start/end | 24 pt below unobscured top; 40 pt end breathing room plus native inset for actual controls/keyboard |
| Body | 17-pt native Body, `max(1.75em, nativeBodyLineHeight)`, 1.25-em paragraph gaps |
| H1 | Sans bold, 34 pt; native Large Title growth from Large; no first-block top margin |
| H2 | Sans semibold, 25.5 pt; native Title 2 growth, about 3rem before a section except at page start |
| H3 | Sans semibold, 21.25 pt; native Title 3 growth. Lower levels retain hierarchy without extra rules |
| H1/H2 rule | One CSS pixel semantic separator, with 1rem padding above it, across the text measure |
| List rhythm | Clear logical marker gutter, wrapped-line alignment, 0.5-em inter-item gaps |
| Anchors | Target about 16 pt below actual unobscured top, not an assumed browser origin |
| Targets | At least 44 x 44 pt, with nonoverlapping hit regions. Grow rows instead of overlapping adjacent task targets |

Heading scaling adds the exact preferred-style point growth from Large to each reference. H1 follows Large Title; H2 is Title 2 + 3.5 pt; H3 is Title 3 + 1.25 pt. Do not keep fixed Body ratios or multiply preferred heading sizes by calibration ratios that invert hierarchy at AX. `rem` follows native-scaled Body. Prefer whole-word wrapping, with emergency wrapping only for a word wider than its column.

Use logical margins/direction for RTL and mixed script, isolating code only where necessary. Never clip diacritics or assume one line box fits every language. At AX, collapse companions/stack metadata before shrinking content. Preserve long titles, complete tag names and distinguishable action labels.

Library navigation uses the system large title **GistPad** with its count subtitle, collapsing on scroll, with no inline title, custom font or manual size. Library section headers, Pinned, the date groups and the collection disclosures, use the system header type with `.headerProminence(.increased)` at every size, with a quiet secondary count and no custom font, color, size or rule. The date groups are plain text. Pinned, Daily Notes, Starred Gists and Archived Gists add a decorative monochrome `pin`, `calendar`, `star` or `archivebox` symbol. Each header's trailing `chevron.down.circle.fill` disclosure button is the Notes control, sized by the header's text style, and the list draws its own chevron where the list style already does. Headers wrap at AX rather than shrinking. Rows keep the ordinary row type and metadata rules. See the [Pinned and date groups contract](design-direction.md#pinned-and-date-groups).

Library secondary disclosures retain their full titles and bare trailing numbers in full-opacity adaptive label ink, including at AX. Align the number with the first title baseline, wrap the title and let a decorative symbol yield before shrinking type. Headers take the system List section-header rhythm at every size, with no custom pitch, gap or transition. Empty sections have no header or reserved space. See the [secondary collection contract](design-direction.md#secondary-collections).

### Shared appearance bridge

The native host resolves semantic sRGB colors, preferred sizes/line heights, scaled monospace, contrast, Bold Text and relevant layout direction. Preview consumes those values through the existing typed bridge/CSS variables. Appearance is separate from document identity/generation: no web view reload, source replacement or lost selection/scroll for a theme change.

Use preferred fonts with current view traits and avoid double scaling. Update attributed spans for metric/Bold Text changes without touching characters, Undo or marked text; defer unsafe restyling during IME/Writing Tools. Color-only updates do not reparse source.

Keep native point metrics as CSS pixels at normal `width=device-width, initial-scale=1`, system sans font fallback and `-webkit-text-size-adjust: 100%`. Do not add another accessibility multiplier or independent body shorthand. Preserve pinch zoom. Standalone-browser CSS fallbacks are not the embedded authority. Invalid appearance retains the last legible theme and emits a diagnostic, not unreadable output.

## 4. Native controls and input

System navigation/toolbars/sheets own placement, grouping, shapes, safe areas and overflow. Supply title + SF Symbol even when only the symbol is visible. Use native cancel/confirm/close roles, clear accessible labels and descriptive body copy for consequential choices. No manual centering spacers or hard-coded Duo rail offsets. [Toolbars][toolbars], [Buttons][buttons].

Edit uses `square.and.pencil`, Preview `eye`, Split `rectangle.split.2x1`. Keep neutral native selected state, exact accessible names, one glass treatment and the scaled 48-pt segment floor. The mode control keeps intrinsic width; long titles truncate first, not the symbols. Other actions retain familiar native symbols: calendar, tag, share, pin, star, archive and gear.

The keyboard accessory is one floating native glass capsule, using `UIGlassEffect`, about 12 pt above the keyboard and 16-pt outer inset where usable width allows. Its compact controls are Aa / Lists / Insert / Intelligence / Hide Keyboard. Bold/Italic can be direct only with room; fold them into Aa before shrinking targets or hiding dismissal. Find stays in the note menu and Command-F, using Apple's find-and-replace bar with its system-owned close control. Note text continues beneath that bar and the accessory through the system soft edge, and the last line stays reachable above them. The retained text view remains input owner; no second editor or reset selection/Undo. [Native glass][glass].

Both source and Preview use native bounce, automatic insets and soft scroll edges only where real controls overlap. At rest the first heading is visible; the final line/caret can scroll above keyboard, accessory and active problem notice. No double inset, CSS fade, fake footer cutoff, nested page scroll surface or blanket touch cancellation. Local table/code scrolling remains independent.

Propagate Reduce Transparency, Increase Contrast, Reduce Motion and Bold Text through native/WebKit surfaces. Preserve native selection, menus, focus outlines, Writing Tools, IME and pinch zoom. Never blanket-disable selection/callouts or remove native menu actions to hide a renderer tell.

## 5. Rendered content

The bundled preview preserves the web Markdown dialect and the user's source. Rendered headings and authored emoji are not duplicated with another giant description heading. Content surfaces are quiet and opaque.

| Element | Presentation |
| --- | --- |
| Tasks | Labeled real controls with 44-pt targets, pending/failure recovery, contrast-safe gray box/check and legible read-only text |
| Links | Semantic link treatment and non-color affordance; no hover-only dependency |
| Contents | Compact disclosure only when requested by the note. Interface-scale label, primary anchor rows, modest hierarchy, 44-pt targets, pressed/focus states and navigation landmark. Do not alter ordinary authored details open state |
| Quotes | 3-pt logical-start rule, 16-pt inset, primary prose rather than faded italics |
| Inline code | Body-size monospace, quiet surface, 2-4 pt horizontal padding, no synthetic backticks |
| Fenced code | Scaled body monospace, 12-16 pt inset, preserved whitespace and local horizontal scrolling. No language rainbow |
| Tables | Body text, semibold header, quiet horizontal separators and authored alignment. No default zebra/outer grid; local scrolling instead of tiny cells |
| Alerts | Kind label, symbol and boundary. Color supplements meaning |
| Footnotes | Native-scaled Footnote, discoverable backlinks, no extra tiny relative reduction |
| Calculations | Current result semibold on the existing selected content surface; previous substitutions regular on content surface. Primary ink, tabular numerals, 6-pt radius, 4-pt horizontal/2-pt vertical padding. Preserve exact value/copy semantics and accessible distinction |
| Diagrams | Neutral default nodes, primary labels and readable strokes, native Body typography, authored meaningful styles/alternative text and explicit enlargement where needed. Scroll locally instead of shrinking |
| Images | Fit width, preserve aspect ratio and meaningful alternative text; enlargement where needed |
| Disclosure | Real details/summary semantics, quiet chevron, Body semibold, 44-pt row, 8-pt label gap and expanded-content spacing, visible pressed/focus states. No mandatory motion/card |

No page-wide horizontal panning, browser tap flash, hover-only controls or fake pointer cues. Preserve heading/link/task semantics and actual keyboard/VoiceOver operation. Rendering changes use source generations and retain the passage; appearance changes only update variables.

## 6. Source syntax theme

Source stays exact Markdown, never lossy rich text. The editor uses the web's GitHub palette for headings, emphasis, quotes, HTML and links, because the user prefers gistpad.dev's editor colors (user, Nov 2). Everything else uses system inks.

| Span | Light | Dark | Light Increased | Dark Increased |
| --- | --- | --- | --- | --- |
| Heading line including `#`, bold, italic | `label` | `#D2A8FF` | `label` | `#E6CCFF` |
| Quote line including `>` | `#22863A` | `#7EE787` | `#155D27` | `#B0F5B7` |
| HTML tag | `#116329` | `#7EE787` | `#0B4B1E` | `#B0F5B7` |
| URL, underlined | `#032F62` | `#A5D6FF` | `#02234A` | `#D1ECFF` |
| Link label and wikilink, underlined | URL color | `label` | URL color | `label` |
| Prose, code, front matter | `label` | `label` | `label` | `label` |
| List bullets and numbers, task brackets, code fence lines | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` |

The web colors live in one small palette in the editor package, next to the heading ink. Bold or italic inside a quote stays purple, like the web.

| Source element | Treatment |
| --- | --- |
| Heading | Body size, bold |
| Strong / emphasis | Bold or italic traits that compose when nested |
| Code / front matter | Body-size monospace in `label`, protected from prose matching. Front matter collapse is explicit only |
| Strikethrough | Struck through, with its markers intact |
| Delimiters and markers | `**`, `_`, `` ` ``, `~~` and link brackets wear their span's ink and style. A heading's `#` and a quote's `>` wear their line's color. Other markers that start a line are `secondaryLabel` |
| Caret / selection / marked text | Native text-entry blue, independent of the personal accent |
| Proposed diff | Before/After labels. Added words primary semibold + underline; removed secondary + strikethrough. No new red/green palette |

Styling is attributes only: no smart-quote rewriting, hidden delimiters, automatic formatting or source mutation. Preserve task targets/state, ordering/nesting, wrapping and native caret. Code/fences/frontmatter resist inline decorations. System Writing Tools excludes code/frontmatter through supported integration; highlighting/replacement never interrupts IME or Writing Tools.

Comment annotations follow the separate [quote contract](design-direction.md#quotes-and-native-selection). No comment-added underline. Ordinary link and proposal-diff underlines remain.

## 7. Review gate

Designer signs off actual surfaces, with installed-device review required for final polish. A stock component, passing build, SVG or single screenshot is not whole-app approval. Award-caliber is an ambition, not an award claim. Lead can accept the delegated nightly outcome without converting unobserved hardware behavior into evidence.

For an implemented app surface, supply Dark captures from one build at Closed and Open, at the default Large text size (user, Nov 2). Include actual keyboard, sheets and relevant empty/loading/offline/failed/read-only/permission states. Name the build, pose and state, and attach images to the channel handoff. Any visible change, even inside a cleanup, shows the user a before and after capture before it merges.

Accessibility text sizes, Light, Increased Contrast, Reduce Transparency, Reduce Motion and Bold Text keep working through system styles and the `isAccessibilitySize` branches, but they aren't captured or validated (user, Nov 2). Measure final content/affordance pairs, including selected surfaces and actual materials. Reusing component evidence does not waive review in a new context. [Accessibility][accessibility].

Connected review must establish:

- Clear purpose, hierarchy, native grouping, direct commands and usable asymmetric safe areas.
- Readable uncut content/actions, full tag names, nonoverlapping targets and no color-only meaning.
- Honest persistence, publication, permission and recovery language; explicit data-risk protections.
- Real selection, native menus, keyboard dismissal, IME, Writing Tools, Undo and passage continuity.
- Actual VoiceOver order/focus and keyboard access, without hidden/occluded accessibility stops.
- Purposeful, interruptible feedback after committed actions, never before persistence or on background refresh.

Continuity needs an observed sequence or recording: type/select, change presentation, continue, Undo. Performance needs measured frame/input behavior. VoiceOver requires traversal; haptics, live-model quality and physical fold behavior require hardware. Mark unobserved gates unverified.

Use **Approved**, **Approved for a named spike only**, or **Changes required**, always with the inspected scope. Spike approval never carries into v1. Keep diagnostics explicitly synthetic/local-only and out of production surfaces. Git/channel hold evidence history, not this current contract.

## Primary references

Platform facts come from Apple. GistPad compositions, contrast targets and exact metrics are product choices, not claims that Apple mandates them.

[materials]: https://developer.apple.com/design/human-interface-guidelines/materials
[adoption]: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
[color]: https://developer.apple.com/design/human-interface-guidelines/color
[resolved]: https://developer.apple.com/documentation/uikit/uicolor/resolvedcolor(with:)
[type]: https://developer.apple.com/design/human-interface-guidelines/typography
[font]: https://developer.apple.com/documentation/uikit/uifont/preferredfont(forTextStyle:compatibleWith:)
[metrics]: https://developer.apple.com/documentation/uikit/uifontmetrics
[toolbars]: https://developer.apple.com/design/human-interface-guidelines/toolbars
[buttons]: https://developer.apple.com/design/human-interface-guidelines/buttons
[glass]: https://developer.apple.com/documentation/uikit/uiglasseffect
[accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
