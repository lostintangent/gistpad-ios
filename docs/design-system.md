# GistPad Native design system

Version 1, October 23, 2026. Owner: Designer. Applies to native UI, the TextKit source editor, the bundled WebKit preview, and later system surfaces.

**A quiet notebook with a precise Markdown engine.** Content is stable, controls are recognizably iOS, and every action tells the truth about its effect. Use system components before custom styling. Modern means the best supported tool for the job, not replacing a reliable text engine merely because a newer wrapper exists.

This is the implementation specification and review gate, not a claim that the current spike passes it. The app targets iOS 27.1 and later. It is personal, installed directly with the user's paid developer account. No marketing onboarding, App Store work, or subscription UI.

**October 24 design reset:** Use [design-direction.md](design-direction.md) for the overnight work through M4, with Designer reviewing the actual surfaces as they land. Earlier Library, palette and decorative proposals below are inputs, not competing specifications. Data-safety rules and explicitly requested fixes to note chrome, keyboard controls, scrolling and syntax remain active. The October 24 saving and Apple Intelligence decisions below supersede the earlier background-save and staged-AI policies.

## 1. Non-negotiable product rules

- Existing notes open rendered. New notes open in source. An interrupted edit resumes at its selection.
- Cover display: Library or one document. Open inner display: Library + document. Deliberate Focus: source + preview, with Library hidden. Never three squeezed columns.
- One document session and native text surface survive presentation changes. Folding never saves, publishes, changes mode, accepts a proposal, or resets undo.
- Local drafts and GitHub publication are different states. Keep local edits durable. Publish after five quiet seconds and on leaving a note when autosave is on; attempt publication on app background regardless of that preference, within the existing background-task lease and eligibility/safety checks.
- Today contains the user's current dated note and template. **No Earlier days, task carryover, automatic journal text, or large-gist Git fallback.** A truncated response warns and blocks unsafe writes.
- Tags apply to gists, not individual files or days. Secret gists and uploaded images are readable by URL.
- Apple Intelligence is the only AI platform. V1 includes system Writing Tools plus exactly three whole-note actions: Ask, Edit and Review. Run on device, with bounded passes covering long notes in full. The user's later October 24 decision skips Private Cloud Compute. No app-owned tag suggestions, selection/section modes, third-party models or permanent chatbot. Generated changes remain proposals until Apply.

The accepted recommendation governs scope. Earlier concept sketches are directional, not production geometry or an exception to these rules.

### Preserve the original app identity

Use the original PWA artwork from `gistpad.dev/public/icon.svg` for the native app icon. Preserve its blue gradient spine, outlined pale cover, coral/amber/teal tabs, writing strokes, proportions and shadow in the default full-color rendition. Do not substitute the simplified warm-binding notebook or another approximation. Adapt asset packaging and system-owned appearance variants without redesigning the master artwork.

### A useful default detail

An unselected wide detail must not open onto a generic Select a gist placeholder. Resolve it in this order:

1. Restore the last accessible note and file for the current account, including its durable local draft and genuine interrupted editing state.
2. With no restorable note, show the existing current-day note in reading mode.
3. If today's note does not exist, show a composed Today landing with the local date and an explicit Start today's note action. This is an invitation, not an automatically created file.

Opening the Library, restoring the app, or unfolding never creates or publishes a note. A default-detail read may fill only a still-unselected detail, never replace a newer user selection. An active note always wins over the fallback, even when it falls outside the current Library filter. A remotely removed note with a recoverable local draft needs a recovery state, not silent abandonment.

Signed-out, offline-without-cache, loading and failed-read states explain the actual condition and provide an appropriate action. Do not conceal those states behind a decorative empty page. Use note in selection/reading copy. Retain gist where the GitHub object's scope matters, such as multiple files, gist-level tags, and unlisted-link warnings.

### Signature craft, not just compliant controls

Correct system components are the floor. A stock grouped list, readable fonts, and a passing accessibility matrix are not the finished product. The production experience needs an identifiable notebook composition and exceptionally direct interactions. These requirements fit the existing M2/M3 scope, not a new feature milestone.

| Moment | Production direction and evidence |
| --- | --- |
| Opening the Library | A notebook collection with three visibly distinct compositions: a Today hero, an adaptive Pinned grid of little notebook cards, and an inset-grouped Notes list. Use the semantic grouped canvas with 20-pt outer margins and 32-pt section separation, not the rejected continuous flat list. Preserve native navigation, swipe, selection and accessibility semantics. Titles lead, metadata recedes, and cached excerpts add context without a new fetch. The signature-moves metrics below supersede earlier flat-list density targets |
| Opening a scoped collection | Starred, Daily Notes and Archive show their name once in navigation, not again above their only list. Remove redundant header space without changing native grouping or row insets. Keep headings where they distinguish real groups, including Home's Pinned Gists and Your Gists |
| Home group headings | Native `Label` headers with `pin.fill` for Pinned Gists and `doc.text` for Your Gists. Preserve title3-bold text and native spacing; use small secondary-gray symbols that scale with Dynamic Type, with no badge or accent. Speak each heading once, treating the image as decorative |
| List counts | Plain localized integers at the trailing edge of real Home/Results headings, scaled subheadline regular secondary gray with tabular digits. No badge, accent or capped count. Counts reflect that group's distinct gists, not files or duplicated pinned membership; localize the unit as "1 gist" / "12 gists", also for Daily Notes and VoiceOver. Wrap below at constrained AX widths rather than truncate the heading. Scoped Starred/Daily Notes/Archive lists remain headerless, using the native navigation subtitle for their unfiltered collection total. Existing Results headings count current matches, not collection totals, and omit the number during searching/failure. Keep last known collection counts through refresh/offline use, omit unknown initial counts and show zero only for a known empty result |
| Home navigation controls | Direct Settings (`gearshape`) at leading and Filter by tags (`tag`) beside Compose at trailing, not secondary-action overflow. Applied filters use neutral `tag.fill` plus an accessible count. Keep the title's collection picker and existing native Search position. Preserve availability, native grouping and 44-pt targets, including folded/AX and leading-pane/rail adaptation |
| Today feels like today | Give the current local date a deliberate typographic treatment beside Today. When actual current-day task data is available, show completed/total with a quiet progress indicator and an accessible text equivalent. No fabricated progress, streaks, weather, greetings, or carryover. Add a line is direct, with its target date pinned when composing starts |
| Unfolding reveals context | The same page remains the visual and interaction anchor as Library appears beside it. Focus deliberately reveals source + preview at the relevant passage. Preserve text, selection, scroll and undo rather than crossfading to a fresh-looking copy. Judge this in motion through Closed, Partially Open and Open, not in independent screenshots |
| Capturing a thought | A native, keyboard-ready composer with one clear commit action. After the durable local commit, reveal the inserted line in its real note rather than a generic success toast. An interrupted composer retains its text. Local capture never masquerades as GitHub publication |
| Completing a task | Keep the line in place, make the checked state precise, and use one restrained checkmark transition and light response after the local commit for a direct toggle. Rejected edits retain a visible recovery path. No confetti, row teleportation, haptic on initial tap, or background-sync celebration |
| Chrome gets out of the way | Use the platform's adaptive toolbar, native Liquid Glass and supported Duo arrangements/reserved regions. Let system chrome respond to scrolling and presentation. Do not imitate it with custom blur, a permanent command dashboard, or decorative fold effects. The page itself stays quiet and opaque |

The sky spine, existing colored tag labels, editorial hierarchy and exact feedback are the recognizable identity. The web is the reference for capability and speed, not a visual template. Titles are user content: display them exactly as written, without extracting emoji faces or inventing fallback illustrations per note. The icon's paper treatment belongs to notebook surfaces, not behind every paragraph. A signature interaction must still be clear with Reduce Motion, increased contrast, VoiceOver, and large type. Review the live error states with the same care as the opening frame; healthy persistence does not need a footer.

### Signature moves

This reset replaces the olive/gold direction and the twice-rejected flat Library. Build in the priority order below, then show the same real-app fixture before and after. A recolor alone is not the finished pass.

| Priority / surface | Memorable move and concrete delta |
| --- | --- |
| 1 / Library | Use `systemGroupedBackground`. Pinned has a title3-bold header with a sky pin, then an adaptive notebook-card grid: 18-pt corners, 120-pt minimum height, 6-pt leading spine in the first tag's actual color or sky, the exact headline title up to two lines at standard sizes, and one cached excerpt or factual file-summary line. Use the existing tinted tag labels. Notes has its own title3-bold header and one inset-grouped surface with 14-pt vertical row padding, inset hairline separators, headline titles, a secondary line, tag labels and a quiet relative-time/file-count line. Pinned notes outside the shelf, such as search results, retain a small sky pin. No outer borders around each row |
| 1 / Today | A full-width notebook hero inside the margins, with 22-pt continuous corners, `secondarySystemGroupedBackground`, 20-pt internal inset and a 4-pt leading sky-gradient spine. Give the day numeral native SF Rounded bold, starting around 44 pt and scaling relative to large title; month uses `accentText`, weekday stays SF. Add up to two real cached excerpt lines and a small genuine task-progress ring beside a readable count. Leave 24 pt above and 32 pt below. No excerpt fetch or appearance-time creation. An existing note opens directly; an absent note has one explicit Start action. Stack at accessibility sizes |
| 1 / Tags | Keep tinted metadata labels with readable full names and soft rounded shape, but remove their redundant inner color dot per the October 24 tag decision. Do not replace them with solid web pills, a new leading strip or a notebook-tab shape. The Tags sheet itself gets lighter, not bigger: remove its duplicate selected-chip panel, grouped cards and All tags heading. Use one plain searchable list with 44-pt minimum total rows, standalone swatch/neutral name/check and one quiet scope footer. Native medium/large detents, initially large at accessibility sizes. Keep editing behind swipe/context and preserve user colors |
| 2 / Reading | A composed, uninterrupted page, with New York for rendered H1/H2 only, SF prose, adaptive ink and 1.5-body line height. Keep the existing heading scales and language fallback. Remove the healthy-state footer entirely. When a problem notice is present, use native scroll-edge underlap and enough end space to reveal the final line. Keep tasks fully legible when read-only. No page texture, permanent contents rail or decorative card around prose |
| 2 / Editing | Readable, colorful Markdown structure using the web's semantic token colors: bold purple headings/strong and green quotes in dark mode, with the light theme and increased-contrast adaptations below. Keep native body-sized fonts and monochrome code, not a fenced-code language rainbow. The keyboard accessory floats as a native glass capsule, with a visible trailing Hide Keyboard button and no overflow. Keep the current passage anchored when moving between source and reading, with caret/selection/Undo intact |
| 2 / File switching | The current exact filename is the native subtitle for a multi-file note; its title menu exposes ordinary files directly and dates in newest-first year/month groups. The selected file has a check. Choosing a file changes the actual mounted document, not just its title. No intermediate Files sheet or custom tab strip |
| 3 / Motion and feedback | Use the native zoom from Today and Pinned notebook cards into their note on compact push navigation, with stable identity, interactive cancellation and a Reduce Motion alternative. Plain Notes rows retain native navigation; side-by-side selection does not zoom. Pin gets one restrained symbol response after commit. Archive retains its real Undo. Manual Save may acknowledge a successful GitHub write once; autosave never buzzes or celebrates. Do not delay opening to animate [9-11, 14] |

Palette and Library/Today/tab composition land first. Reading/editor/file chrome follow in the same connected flow. Motion is last, not a substitute for composition. The source-identity safety fix ships independently of this design pass.

Pinned grid metrics: 12-pt gaps and at least 156 pt per card, yielding two columns from 324 usable content points, more when unfolded, and one on narrower/accessibility layouts. Use a 120-pt minimum, never fixed, height; let large text grow. Existing tag labels keep full names and honest overflow, not cropped decorative fragments or tiny independent hit targets. Context menus preserve the row actions.

The quiet metadata line combines relative time with a `doc.on.doc` count when more than one file is known. Do not fetch for decoration or show a guessed count. Daily notes and Archived remain clear native navigation rows with trailing collection counts at the bottom of the Library, not hidden only in the overflow menu.

Three daily moments make the notebook feel alive:

- **A friendly date:** the rounded day numeral is expressive immediately, before any animation. Include it in the first Library/Today pass. Use the native rounded design, not a fixed font name or an oversized date that squeezes the excerpt. [15]
- **A task clicks into place:** a direct task-toggle action gets one short checkmark response and light haptic only after its local source commit succeeds. The native host owns the haptic; the reading checkbox resolves once rather than replaying on render. Today's real progress fills to the committed value when that leaf is visible. No row movement, refresh/relaunch feedback, or haptic for every typed character. Reduce Motion uses the settled check/progress immediately. [9-11]
- **A fresh page:** deliberate local-note creation opens the real, focused editor immediately. After durable creation, briefly reveal its leading sky spine once, around 180-220 ms, without moving text or delaying the keyboard. Reduce Motion shows the settled page without the reveal. Empty-notebook and first-run invitations use the original notebook artwork at 48-64 pt, not a generic document symbol or a giant hero. Do not substitute it for offline, error or no-search-results states.

## 2. Color: one set of roles, four appearances

### System roles

Use semantic colors, resolved against the **containing view's traits**. Never copy sample system RGB values into assets or CSS. Colors can change between OS releases, appearances, elevated presentations, and accessibility settings. [1, 2]

| Token | Native source | Preview CSS variable | Use |
| --- | --- | --- | --- |
| `page` | `UIColor.systemBackground` | `--gp-page` | Opaque native editor/reading backing; nested transparent WebKit inherits this page |
| `surface` | `UIColor.secondarySystemBackground` | `--gp-surface` | Code blocks and quiet grouped content |
| `surfaceRaised` | `UIColor.tertiarySystemBackground` | `--gp-surface-raised` | Only a genuine nested content surface |
| `text` | Adaptive custom `ink` below | `--gp-text` | App-owned prose, headings and task labels; system-owned chrome retains semantic foregrounds |
| `textSecondary` | `UIColor.secondaryLabel` | `--gp-text-secondary` | Supporting metadata, not essential source syntax |
| `separator` | `UIColor.separator` | `--gp-separator` | Nonessential dividers |
| `boundary` | `UIColor.opaqueSeparator` | `--gp-boundary` | Visible content boundaries, checked at actual contrast |
| `link` | `UIColor.link` | `--gp-link` | External links and wikilinks, with a non-color affordance |
| `error` | `UIColor.systemRed` | `--gp-error` | Errors, with a symbol and explanation |
| `success` | `UIColor.systemGreen` | `--gp-success` | Explicit success, never the only status signal |

System navigation/list materials retain their standard styles. `surface` is not an instruction to put every row inside a card. Do not use `tertiaryLabel`, opacity, or separator colors for necessary small text.

### Custom roles

The ink values below are exact sRGB assets. The accent values are the earlier sky reference, not a replacement for the saved profile color or permission to tint chrome. The current derivation and allowed uses are specified in [Color: personal content, neutral controls](design-direction.md#color-personal-content-neutral-controls). Keep shared native/preview roles with four appearances, not separate inline RGB literals.

| Token / CSS suffix | Light | Dark | Light increased | Dark increased |
| --- | --- | --- | --- | --- |
| `ink` / `text` | `#1E293B` | `#E2E8F0` | `#0F172A` | `#F8FAFC` |
| `accentText` / `accent-text` | `#0369A1` | `#7DD3FC` | `#075985` | `#BAE6FD` |
| `accentFill` / `accent-fill` | `#0EA5E9` | `#38BDF8` | `#0EA5E9` | `#7DD3FC` |
| `onAccent` / `on-accent` | `#0F172A` | `#0F172A` | `#0F172A` | `#0F172A` |
| `selectedSurface` / `selected-surface` | `#E7F6FD` | `#0B3548` | `#D4EEFC` | `#134B63` |

Prefix each CSS suffix with `--gp-`. Personal `selectedSurface` now belongs to the Today date treatment, not Library/sidebar selection or OS text selection. Library selection uses native neutral surfaces and selected traits.

Use personal accent only for Today content and the preference swatch, as enumerated in the canonical direction. The user's later October 24 feedback restores muted secondary gray for document bullets, numbers and task boxes, including checked boxes, in Edit and Preview. Enabled native chrome, keyboard tools, menu commands and sheet actions use primary adaptive monochrome ink, with native neutral prominent styling where needed. Secondary ink is for metadata/progress and document list markers, not a dimmed enabled action. Preserve destructive red, tag colors, native text-entry blue and switch defaults. Do not apply personal tint at the app, navigation or sheet root. System controls own material/foreground and disabled-state adaptation. Links retain their semantic treatment and non-color affordance.

The decorative spine uses the original `#5AD1FA` to `#0EA5E9` gradient. Neither stop is suitable for small text on white (1.76:1 and 2.77:1). Library uses semantic grouped surfaces, with the icon's paper `#FFFFFF` to `#E2E8F0` gradient reserved for small original-artwork illustrations rather than overriding those surfaces. Keep the source and reading page semantic and flat. The icon's coral, amber and teal do not replace existing profile colors or force a new tag palette.

The shared custom text roles above clear 4.5:1 against reference light canvases `#FFFFFF`/`#F2F2F7` and dark canvases `#000000`/`#1C1C1E`. The lowest measured normal-mode text ratio is 5.32:1, increased-mode 6.78:1. `onAccent` against its fill exceeds 6.4:1 in all variants. Source-only token colors and their quote-background caveat are specified in section 6. Those reference backgrounds are **test inputs, not a definition of system colors**. Measure final resolved text/background pairs, selected surfaces, actual materials, Today paper and tag fills on the shipping OS. Never assume these reference checks certify the whole screen.

User-defined tag colors stay compatible with the web. Show the complete tag name in primary semantic ink. Metadata pills carry color in their tinted fill without an inner dot; plain picker rows use one standalone swatch instead. Chosen tags also have a neutral checkmark. A tag's color is not an error or sync status.

### Tags with presence

Tags are small colored labels, not a comma-separated gray sentence. Use one shared presentation across Library metadata, the selected note's metadata, and tag selection.

- **Label:** retain the installed scaled `.footnote` medium label, primary text, 8-pt horizontal / 4-pt vertical padding and softly rounded 8-pt shape. Remove the inner color dot consistently from all metadata pills. Composite the tag color into `surface` at 24% in light and 28% in dark, producing an opaque final fill with recognizable color. Do not replace it with solid pills, a leading strip or asymmetric corners. Do not lower the whole label's opacity or use arbitrary user color as its text color. Increased contrast adds a visible boundary and retains the complete name. Check final text/fill contrast for white, black, saturated yellow, similar hues and missing-color tags, targeting 4.5:1 normally and 7:1 with Increased Contrast. Black, white and missing-color tags remain truthfully neutral rather than receiving invented hues.
- **Library rows:** place labels below the title/excerpt, with 6-pt gaps. At standard sizes show up to two complete names plus a truthful `+N` overflow label. Never cut a chip midway or abbreviate two names into the same string. At accessibility sizes wrap/grow rather than compressing text. Row tags are metadata, not nested buttons inside the note's navigation link. The note's labeled Tags action reveals the complete set.
- **Note metadata:** provide one labeled Tags route in native note chrome. Its editable sheet is a single plain native searchable list: color swatch, full name and selected check. No duplicated On this note chip shelf, All tags heading or rounded group cards. The total row target is at least 44 pt, not a 44-pt inner control plus List padding; grow for wrapping/accessibility. Offer medium/large native sheet detents, starting large at accessibility sizes. Use one scope footer, **Applies to every file in this gist.** A nonmutating presentation shows the assigned tags in the same compact list without toggle checks, plus the native Close action. GitHub source access is a separate capability: a signed-in user can tag someone else's gist, and incomplete source does not by itself block profile-only tag changes. Use a nonmutating presentation only when the account lacks profile-write capability or no safe account-scoped gist association exists. A transient offline/save failure preserves local choices with Retry rather than changing their permission. Avoid a separate information-only sheet that duplicates the Tags editor. Do not pin a new ribbon over the writing canvas or insert tags into the Markdown file.
- **Filtering:** selected search/filter tokens use the same name and color identity plus a checkmark or explicit remove affordance. Show the matching rule and Clear filters. An interactive label has a nonoverlapping 44-pt target. The full tag picker remains a native searchable list with color dot, name and selected checkmark, not a wall of tiny pills.
- **No color escalation:** a selected note uses a native neutral selection surface without recoloring its tag labels. Preserve the user's actual web colors and distinguish a tag selection from a failed metadata save. An unsuccessful edit retains the user's choice with an inline Retry, not a silently reverted success state.

The Tags and Filter by tags sheets use primary neutral ink for names, selection checks and Done/Save/Close. Their untinted picker rows retain the standalone color dot as the only tag-colored element. Keep each picker row to dot, name and check. Expose **Edit Tag...** through swipe/context actions and a named accessibility action instead of a second pencil button in every row. Do not explain the conventional Cancel/Done interaction in a second paragraph. Library timestamps use scaled footnote regular, allowing titles to lead without fading small text below 4.5:1.

Swatches are metadata, not radio controls. Do not add a universal primary/black outline. Use an unoutlined fill when it is distinct, with a subtle own-hue hairline only where separation is needed. White uses a neutral gray hairline rather than an invisible white edge. Increase Contrast can strengthen the necessary boundary without changing the tag's color identity. Selection remains a separate checkmark and accessibility state.

### Purposeful delight

Animation and accent details are welcome when they make writing, reading or navigation feel more direct. Quiet does not mean lifeless. Prefer the system control's pressed, selection and presentation behavior, then add only the missing explanatory transition.

| Interaction | Intended character |
| --- | --- |
| Choosing a tag/filter | Keep the tapped label anchored. A short fill/checkmark transition makes the choice visible; a single settled list update follows. Never animate a fresh result order on every typed character or duplicate the system haptic |
| Opening/closing a note | Native navigation owns the gesture and interactive cancellation. A source-to-destination relationship is desirable only when it survives back gestures, large type and interrupted transitions. Do not replace native navigation with a bespoke page-flip |
| Source and reading | Preserve the relevant passage and the persistent editor. Let mode chrome change crisply while the document remains the anchor. No full-page flash, fake typing or slide that implies another note |
| Committing a captured line | Reveal the actual inserted line once, using a brief `selectedSurface` highlight that clears. Never replay it on refresh or use an ongoing pulse |
| Task completion | A single restrained checkmark transition after local commit. Keep the row and text stable. Optional light feedback is reserved for that committed user action |
| Save status | A quiet content transition when the truthful state changes. No pill bounce, spinner after completion, autosave toast or success animation competing with the sentence being written |

For custom state changes, start around 160-220 ms ease-out and evaluate on the device. This is a tuning range, not a replacement for system spring parameters. Motion must be interruptible, and Reduce Motion uses an immediate state change or brief nonspatial fade. A flourish that damages input responsiveness, reading position or clarity is removed. Custom gradients or accent strokes are not categorically banned, but must serve a specific focal point and pass the same appearance/accessibility review as typography.

## 3. Typography and Dynamic Type

Use system font APIs with language fallback: SF by default, SF Rounded for the Today day numeral, and New York for rendered H1/H2. Keep Library titles, native chrome, reading body and source in SF. No bundled system fonts, fixed-size UI typography, condensed prose, manual tracking on body text, or all-uppercase labels needed to understand the product. [3, 15]

| Role | Native text style | Treatment at default Large |
| --- | --- | --- |
| Screen title | System navigation title | Let navigation adapt size and placement |
| Document H1 | `.title` / `UIFont.TextStyle.title1`, serif design | New York bold, approximately 28 pt |
| H2 | `.title2`, serif design | New York semibold, approximately 22 pt |
| H3 | `.title3` | Semibold, approximately 20 pt |
| H4-H6 / section heading | `.headline` | Semibold, approximately 17 pt, preserve semantic heading levels |
| Prose / source / task | `.body` | Regular, approximately 17 pt |
| Library title | `.headline` | Default semibold, allow two lines then a detail route. No repeated pin inside Pinned; retain a small pin for a pinned note outside that shelf. Do not let a status symbol steal title width at accessibility sizes |
| Secondary metadata | `.subheadline` or `.footnote` | Not smaller merely to preserve a tight row |
| Code | Monospaced system font at scaled body size | Regular, no `.88em` reduction |
| Status / footnotes | `.footnote` | Approximately 13 pt, scales, remains readable |
| Today day numeral | Rounded design, scaled relative to `.largeTitle` | Bold, starting around 44 pt; other date components remain SF |

Point sizes are reference values only. Native style APIs determine actual size. All labels wrap/grow at large categories. Required actions must not truncate to identical labels. Source headings stay body-sized bold, not the large rendered heading sizes.

For UIKit, resolve `UIFont.preferredFont(forTextStyle:compatibleWith:)` using the current view traits and update attributed spans when those traits change. Use `UIFontMetrics` for a custom monospaced base. Do not double-scale a font that is already preferred/scaled. Attribute refresh must not change characters, marked text, undo, selection, or the current reading anchor. Defer restyling while composition or Writing Tools is active, then apply current traits safely. [4, 5]

### Shared preview appearance contract

**The host is the authority for Dynamic Type and appearance.** Resolve semantic colors and preferred font metrics in native code, then update the page's CSS variables in one transaction. The appearance update is presentation data, separate from document identity and draft generation. It must not reload the web view, replace Markdown, or erase selection/scroll.

The payload needs:

- Appearance and contrast, plus resolved sRGB colors for the roles in section 2.
- Preferred point sizes and native line heights for body, title1/title2/title3, headline, and footnote, plus the scaled monospaced body size.
- Bold Text state and layout direction when relevant to typography. Content direction remains determined by the content, not forced from the app language.

CSS metric names: `--gp-body-size`, `--gp-body-line-height`, `--gp-title1-size`, `--gp-title1-line-height`, `--gp-title2-size`, `--gp-title2-line-height`, `--gp-title3-size`, `--gp-title3-line-height`, `--gp-headline-size`, `--gp-headline-line-height`, `--gp-footnote-size`, `--gp-footnote-line-height`, `--gp-code-size`.

Resolve title1/title2 metrics using the preferred font descriptor's `.serif` design, which Apple maps to New York. Apply `font-family: ui-serif, serif` only to rendered H1/H2 in WebKit. Keep native language fallback and Bold Text. Do not bundle the font or hard-code an installed/private face name. [15, 16]

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

Use role-driven native actions for sheet chrome: `.cancel` discards the pending operation, `.confirm` commits it, and `.close` dismisses a read-only surface. Keep clear accessible names such as Cancel and Save Tags. Let native toolbar/title placement adapt to Duo rather than inserting manual centering spacers. Consequential choices such as Use GitHub Version or Restore File retain descriptive text in the sheet body instead of becoming unexplained checkmarks. [13]

For multi-file gists, show the active filename in the native subtitle. Opening the note-title menu reveals ordinary filenames directly and dated series in newest-first year/month groups within that same menu, with a checkmark on the selected file. Match the web's grouping rules using UTC Gregorian dates, never grouping UTC midnight in the viewer's local zone. Do not require Files in this gist followed by another sheet merely to choose a file. Keep filenames exact, including non-Markdown files. Separate Add File and Rename File actions from selection. Initial file resolution follows the web resolver, including newest-file selection for a detected dated series and README selection otherwise, with its fallback. Explicitly choosing a file always opens that exact file. The mounted source editor, preview and title must share that account/draft/file identity before editing is enabled.

The note's overflow menu uses native sections. Begin with one compact Pin/Star/Share/Copy Link control group, with accessible names and current toggle states. Follow with content/view actions (Tags, Files, Source & Preview, Find), Open in GitHub, Archive, then destructive Delete isolated at the bottom. Use a real native Menu with Sections if automatic secondary-action placement cannot express this hierarchy. Do not fake headings with disabled buttons or draw custom separator views.

The page's native backing stays opaque. WebKit and its HTML canvas may be transparent over that backing so content can underlap system chrome; this does not turn prose into a glass panel. Code/alerts use content surfaces, not glass. A translucent panel behind every row, tag and paragraph is a rejection. Never hand-render blur/highlight edges to imitate system glass.

The source keyboard accessory is one floating native glass capsule, not a full-width flat toolbar attached to the keyboard's top border. Keep 12 pt of clear space between the capsule and keyboard and 16-pt outer insets where usable width permits. Use native glass (`UIGlassEffect` for a UIKit accessory), not a custom blur imitation. Its six visible essentials are Aa, Bold, Italic, Lists, Insert and a trailing Hide Keyboard button. Every target is at least 44 pt, and Hide Keyboard never moves into overflow. At narrow/accessibility widths, fold Bold/Italic into Aa before sacrificing dismissal or shrinking targets. Find moves to the note menu and keeps Command-F. The retained text view remains the input owner; the capsule does not add a second editor or reset selection/Undo. [17]

Both source and reading use native soft top/bottom scroll edges, normal bounce and automatic content insets. Extend content beneath the container's navigation/bottom regions without ignoring the keyboard or extending the chrome itself. At rest the first heading is below navigation; the final line and source caret can scroll fully above a visible accessory or problem notice. No doubled inset, clipped hard seam or CSS gradient over document text. Anchor/task scrolling must account for the native adjusted insets.

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

The editor is Markdown source, not a lossy rich-text conversion. Use familiar semantic Markdown color, not a gray-only approximation. The web reference is `src/features/editor/extensions/theme.ts`, which uses `@uiw/codemirror-theme-github`. Native typography and input remain iOS-owned.

| Source token | Light | Dark | Light increased | Dark increased |
| --- | --- | --- | --- | --- |
| Heading / strong / emphasis | `#1E293B` | `#D2A8FF` | `#0F172A` | `#E6CCFF` |
| Quote | `#22863A` | `#7EE787` | `#155D27` | `#B0F5B7` |
| HTML tag | `#116329` | `#7EE787` | `#0B4B1E` | `#B0F5B7` |
| URL destination | `#032F62` | `#A5D6FF` | `#02234A` | `#D1ECFF` |

These dynamic source colors replace the previous `syntaxMuted`/`syntaxCode` styling contract. Preserve the exact web-light quote on the white source page, where it measures 4.63:1. It is only 4.15:1 on the secondary gray reference; if a quote can appear on that surface, use `#1E7A34` there (4.84:1). Increased-contrast variants clear AA on both reference canvases. Resolve appearance through dynamic native colors, without rewriting or reparsing source solely to change appearance.

List markers are the exception to the colored syntax palette. The user's later October 24 feedback restores the existing `InterfaceTheme.syntaxMuted` role for bullets, ordered numbers and task delimiters in every state. Preview uses the marker-only `--gp-list-marker` for equivalent markers and task-box borders/checked fills, with a contrasting checkmark. Resolve an opaque native secondary gray against the page and minimally adjust for 4.5:1 normally and 7:1 with Increased Contrast. Do not globally recolor secondary captions or copy Source's slate palette to them. Preserve ordinary item text, source bytes, task state, targets, wrapping and the native blue caret.

| Source element | Style |
| --- | --- |
| Ordinary prose | Body regular, `text` |
| Whole heading, including `#` markers | Body bold, heading token; preserve every source character |
| Strong / emphasis | Their token color, with bold / italic respectively; compose both traits when nested |
| Whole blockquote line, including `>` | Quote token; nested emphasis/strong/link/code retain their own valid styles |
| Ordered number / unordered bullet | Muted source-marker ink; list-item text stays body ink |
| Element punctuation | Same readable size and color as its owning element, not independently grayed |
| Unchecked task marker | Muted source-marker ink, same size; no personal accent |
| Checked marker | Muted source-marker ink; preserve explicit checked syntax and do not dim the task's text |
| Inline/fenced code | Monospaced scaled body in ink; optional `surface` block background, no language-token rainbow |
| Link label / wikilink | Underlined; URL color in light mode, inherited ink in dark mode as in the web theme; source delimiters remain visible |
| URL destination | URL token, underlined; no hide/replace without an explicit source view |
| HTML tag | HTML token, without misclassifying autolinks or code as HTML |
| Strikethrough | Line-through on the valid content span, with source markers intact |
| Frontmatter | Monospaced scaled body in ink; explicit collapse affordance only |
| Selection, caret, marked text | Native text-entry blue and selection behavior, independent of neutral chrome and saved accent; preserve marked-text handling |
| Proposed diff | Before/After labels; added words primary semibold and underlined, removed words secondary and struck through. No personal accent or new red/green palette |

Do not use opacity-faded entire code blocks, a rainbow of language tokens by default, giant source headings, or an active-line highlight that competes with selection. Valid inline code, fences and frontmatter remain protected from prose-role matching. Syntax changes must be pure attributes. No rewriting smart quotes, invisible delimiter removal, or automatic code formatting on appearance changes.

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
| Tables | Body-size text with a semibold header and quiet horizontal separators. No outer box, vertical cell grid, or default zebra stripes. Retain authored column alignment and table semantics. Scroll within the block instead of shrinking cells |
| Alerts | Kind label + symbol + boundary. Color supplements the meaning. Match shared roles in every contrast mode |
| Footnotes | Scaled footnote style, discoverable backlinks, no 0.8-em unreadable reduction |
| Calculator results | Current result: semibold body text on `selectedSurface`, with a 6-pt radius and 4-pt inline / 2-pt block padding. Previous-result substitutions: regular body text on `surface`. Both use `text`, with tabular numerals when available. No fixed orange/green status chips. Preserve exact expression/value/copy behavior and label the current versus previous result accessibly |
| Diagrams | Neutral default nodes on `surface`, primary text labels, and `textSecondary` strokes/arrows measured at 3:1 against their actual surroundings. No default lavender. Use the native body font/size, preserve authored meaningful styles, and scroll within the block rather than shrinking labels. Keep alternative text and an explicit enlargement route where needed |
| Images | Fit available width, preserve aspect ratio, meaningful alternative text; explicit enlargement if needed |
| Disclosure content | Keep real details/summary semantics, replacing only the browser triangle with a quiet stroked chevron. Body-size semibold summary, 44-pt whole-row target, 8-pt label gap, visible pressed/focus states, and 8-pt space before expanded content. The chevron indicates collapsed/expanded state, with no mandatory motion or card wrapper |
| Empty/error content | Native-state treatment with an explanation and a real action, not a blank document |

Use logical CSS properties for RTL, with content-aware direction for mixed-script paragraphs. Isolate code direction where necessary without forcing the whole note LTR. No clipped diacritics or line boxes at large size. Do not assume a fixed `line-height` suits every script.

Remove browser tells without removing accessibility: no hover-only copy/link buttons, purple selection override, pointer-hand styling as the primary cue, default tap-flash, two nested page scroll views, overscroll glow, or web-wide horizontal panning. The WebKit host owns one document scroll surface with normal native bounce and soft system scroll edges. This supersedes the earlier preview no-bounce rule. Block-level table/code scrolling still works independently.

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

### Quiet healthy editing, explicit problems

Remove the footer, its container, padding and reserved inset for `unsaved`, `savedLocally`, `savingToGitHub` and `savedToGitHub`; do not leave an empty strip. Local durability and GitHub publication remain separate internally, but the editor does not narrate that pipeline. Do not add autosave spinners, success receipts or generic read-only labels to the healthy writing/reading edge.

Routine remote-check/connection status follows the canonical native toolbar policy in [design-direction.md](design-direction.md). Home uses the existing Search position: after about 0.4 s, replace its magnifying glass with a native spinner while keeping Search enabled, labeled and tappable. Restore the glyph when checking ends. No separate Home status footer or empty strip remains. A persistent actionable problem restores normal Search and adds one quiet adjacent exclamation button in the existing toolbar, keeping Search and recovery separately one tap away. An already-open query retains focus. The note's accepted trailing status placement stays unchanged. When the writing keyboard covers that note slot, remove the occluded control from accessibility traversal and restore the unresolved status after dismissal. Do not move it into the keyboard accessory or add a floating overlay. This does not hide or weaken the explicit save-safety notices below.

Hide Save to GitHub when autosave is effectively enabled. Keep manual Save available when the preference is off, after a publication failure, and while a conflict-reviewed draft's durable `autosavePaused` requires explicit publication. The effective flag must reflect that pause rather than the profile preference alone. Hiding the control never changes publication policy.

Known offline status with unpublished edits gets one quiet `icloud.slash` toolbar glyph. Its accessible label is **Offline. Changes haven't reached GitHub.** Tapping explains that changes are kept locally and eligible autosave resumes online while the app is open. Offline with nothing pending stays silent.

Only actionable problems get one compact native notice with a clear recovery action. Keep raw diagnostics behind Details rather than several paragraphs. Let large type wrap naturally, preserve a 44-pt action target and retain the notice until resolved. A local persistence failure remains prominent and must not look like successful offline storage.

| Real condition | Notice / action |
| --- | --- |
| Publication failed, local copy safe | Couldn't sync. / Retry |
| Local write failed | Changes aren't saved. Keep this note open. / Retry |
| Changed remotely | Changed on GitHub. / Review |
| Account needs reconnection | Reconnect GitHub to sync. / Reconnect |
| Gist creation uncertain | Note creation not confirmed. / Check GitHub; never blind duplicate creation |
| Publication uncertain | Save not confirmed. / Check Status |
| Publication blocked | Can't sync this note. / Details with the actual reason and recovery path |
| No persistence in an engineering fixture | Mark the evidence as synthetic and local-only; never claim actual saving or upload |

Do not call queued or in-memory data Saved. Preserve the failed operation and give a recovery action. Status is accessible text, not just a colored dot. Errors remain long enough to act, not solely in an expiring toast.

### Inserting a photo

**Entry:** use **Insert > Photo** in the native keyboard formatting bar, with a labeled `plus` menu and `photo` item. Keep this entry reusable by the fuller formatting bar. Use the system PhotosPicker for one image, not a custom photo browser or an app-wide library-permission screen. [12] Preserve the originating account, draft, accepted generation and UTF-16 insertion location before presenting it. Insert after a selected passage rather than replacing its text. Disable mutation for read-only/incomplete notes and during IME or Writing Tools transactions.

**Public-image notice:** before this account's first pick, present a native, dismissible sheet titled **Photos are public** with this body:

> Photos you choose are uploaded to GistPad's public image storage. Anyone with an image link can view them, even in a secret gist. Location metadata is removed, but visible details remain.

Use **Continue** and **Cancel**. Continue opens PhotosPicker, not an upload. Remember acknowledgement locally for this account only, and keep this disclosure available from the photo entry's help. A notice dismissal, picker cancellation or failed image load creates no upload. The notice must fit large type through natural scrolling, not smaller text. This is a privacy explanation, not a claim that a secret gist protects its images.

**Pending presentation:** use a native attachment row within the note, above any active problem notice and the keyboard. It remains available when the healthy save footer is absent. Show a small thumbnail when available, **Photo**, a scaled readable state, and the appropriate recovery action. It is not a modal progress screen, translucent card, or literal text attachment. Pending UI never adds provisional Markdown, object-replacement characters, invented URLs or hidden source markers. Copy, share, preview and canonical persistence continue to use the unchanged source. This note-local row is the safe first implementation rather than introducing unproved in-text decorations into the retained TextKit session.

| Actual state | Row language and action |
| --- | --- |
| Loading a picker item / normalizing its pixels | **Preparing photo...** with indeterminate activity. No Saved claim until local queue persistence succeeds |
| Picker transfer or image conversion failed | **Couldn't prepare this photo.** Explain an oversize/invalid image when known, with **Choose Another Photo**. No empty success-shaped row |
| Protected bytes durably queued | **Photo saved on this iPhone**. Upload begins when eligible |
| `.waitingForGist` | **Save this note to GitHub to upload the photo.** Use the existing deliberate Save action. Never create or publish a gist merely to release the queue |
| `.offline` | **Saved on this iPhone. Waiting for connection.** No infinite active spinner |
| `.uploading` | **Uploading photo...** with indeterminate activity, unless the transport exposes real progress. No guessed percentage |
| `.uncertain` | **Checking upload...** while reconciling the existing stable asset ID. Do not offer a duplicate upload |
| `.reconnect` | **Reconnect to upload** with **Reconnect GitHub**. Retain the local photo |
| `.failed` | **Couldn't upload photo** with **Retry**, preserving the actual useful failure explanation. Respect a server retry delay rather than presenting an immediately actionable retry |
| `.uploaded`, original target still valid | Commit insertion through the session's durable-edit hook, then reveal the actual inserted Markdown |
| `.uploaded`, target or insertion generation changed / composition active | **Photo ready** with **Insert Here**, available only in its originating note at a fresh safe cursor. During composition, explain **Finish the current edit to insert the photo** |
| Local queue/insertion persistence failed | **Couldn't save this photo on this iPhone** with **Retry**. Keep available image data and the failure visible, without claiming an inserted or durable result |
| `.inserted` | Remove the pending row only after the durable receipt and source edit succeed. Normal note save state remains authoritative |

Resume eligible work on foreground/reconnection for the same account. Never insert into whichever note happens to be open when an upload finishes. A stale anchor requires an explicit **Insert Here** using a fresh accepted generation and zero-length insertion range in the original draft. Do not guess a shifted offset or overwrite newer typing. Defer insertion during marked text or Writing Tools. Apply the verified URL as exactly one native undoable edit, retaining normal editable Markdown and alternative-text syntax. Reveal it once without stealing an unrelated selection. Undo removes the source insertion, not the public storage object, and must not trigger automatic reinsertion.

Removing a pending item requires **Remove Pending Photo?** confirmation and must explain **This removes the pending photo from this note. It does not delete any uploaded image.** Do not promise upload cancellation or remote deletion that the queue API cannot perform. Disable removal during an active upload if cancellation is not supported. Multiple pending items remain reachable without letting a fixed accessory consume the whole AX3 editing viewport.

Keep the thumbnail/status/action traversal logical for VoiceOver. Do not announce every progress update, move focus on background completion, or dim the entire row. Required evidence includes the first-use notice and cancellation, iCloud/picker-load failure, offline relaunch, an unpublished note with autosave off, upload reconciliation, stale insertion, switching account/note, a failed local commit, one Undo with no reinsertion, and Large/AX3 with the real keyboard. Live upload still requires the user's explicit test approval.

## 9. Conflict review: local choice before publication

### Entry and composition

Keep the inline note state **This note changed elsewhere** with **Review changes**. Do not interrupt writing with a modal alert or open review automatically. Publishing is paused while the conflict remains unresolved, while local persistence continues.

Review changes opens one native, large sheet titled **Review changes**, with the filename and **Your draft is saved on this iPhone. Nothing will be published from this review.** The sheet dismisses without losing the conflict or the source editor's place. On the cover, use one readable column. On the open display the sheet may be wider, but never squeeze base/local/remote into three columns.

Use a native segmented control for **Changes**, **My Draft**, and **GitHub**. Changes shows deterministic source differences from the saved base, grouped and labeled **On this iPhone** and **On GitHub**. Added/removed lines have explicit `+`/`-` and labels, with color only supplementary. Preserve whitespace and Markdown characters. Long source lines scroll inside their block. My Draft and GitHub show full read-only source for inspection, not lossy rendered substitutes. Base is available through **Show original**, not a permanent fourth column. Review source uses the same scaled monospace and semantic colors as code.

### Choices and exact effects

| Available evidence | Choice | Effect |
| --- | --- | --- |
| `suggestedMerge` contains a deterministic nonoverlapping merge | **Review combined version**, then **Use combined draft** | Preview the proposed source and its diff against the current local draft. Apply only after that explicit choice. This is not AI and not a claim that the prose is semantically correct |
| Both local and remote are complete | **Use My Draft** | Retain local text and accept the inspected GitHub version as the comparison baseline. Explain that a later Save to GitHub replaces the inspected remote file with this version. Do not publish from the sheet |
| A complete remote file exists | **Use GitHub Version** | Show a confirmation that this replaces the current local text, with Cancel as the safe choice. Preserve a durable recovery snapshot. Apply as one undoable local edit, without an automatic write |
| The remote file is verifiably absent (`remote == nil`) | **Keep Local Draft**; optionally **Restore File...** | Never present a missing file as empty content. Keep the draft recoverable. Restoration requires an explicit confirmation naming the file and a fresh check that the containing gist still exists. A missing whole gist is a different recovery case, not an implicit new-gist creation |
| Remote is truncated, unavailable, or unverified | **Retry** / **Reconnect GitHub**, as appropriate | No Use GitHub or merge choice based on incomplete content. A timeout or 404 without sufficient evidence is not proof the user's draft should be discarded |

Overlapping edits have no combined-version promise. The user can inspect both versions, copy exact passages using native selection, and choose a complete version. Do not add a per-hunk merge editor or a second live canonical text editor to v1. A dismissible explanation states **Both versions changed the same passage. Choose a version, or return to your draft to combine the changes yourself.**

### Stale review, failure and safety

- Bind the review to account, draft/file identity, local generation, base and the inspected remote revision. Revalidate before Apply. If local text changed, leave it untouched and show **Your draft changed while this review was open. Review the latest draft.** Retain an inspectable proposal; never apply an old whole-file replacement over newer typing.
- A foreground remote refresh may invalidate the reviewed remote revision. Do not silently swap the GitHub tab underneath the reader. Show **GitHub has a newer version** and an explicit refresh action. Publication performs the coordinator's fresh-read/conflict check again, even after a successful review.
- Save a recovery snapshot before replacing text. The session owns the transaction, selection and undo. Apply replacement as one local undo step and a new generation; choosing unchanged text does not need a fake empty undo entry. Do not call `resolveConflict` before the active session can safely accept the transaction. Defer application while IME composition or Writing Tools is active, with visible **Finish the current edit to apply this version** guidance.
- Keep timed/leave-note autosave paused after resolving review until a deliberate **Save to GitHub**. After a durable local result, return to the note with its manual Save action still reachable, even when the profile preference enables autosave. Under the October 24 policy, background Save is manual-save-equivalent and can clear this pause, with the existing fresh-read/conflict and eligibility checks. No combined Apply & Publish, healthy local-save footer or success claim before persistence succeeds.
- A local storage failure leaves the review open with its proposal intact and an actionable error. Never dismiss into Saved or lose the original on failure. Dismissal, account switching and process termination preserve the unresolved durable draft.

Required evidence includes a nonoverlapping proposal, overlapping edits, a remotely removed file, stale local generation, changed remote revision, local storage failure, offline inspection and AX3/VoiceOver traversal. Include a real undo after adopting the remote/combined source. Neither a diff screenshot nor a successful PATCH proves the safety of this flow.

## 10. Review gate for every UI surface

**No production UI task closes without Designer sign-off on the actual installed Duo app.** Simulator evidence can establish scoped layout approval, not final device polish or hardware behavior. A polished SVG, passing build, stock component, or Light-mode screenshot alone is not sign-off. Award-caliber is the quality ambition, not a claim of an Apple award.

Review the connected Library > open note > read > edit > switch file flow, including the real keyboard, grouped menus, problem-only sync notices and return navigation. Assess hierarchy, breathing room, directness and continuity in that experience, not just each isolated fixture. Actual on-device feedback overrides earlier still-image density targets. Fixing correctness or basic usability does not by itself establish the intended design quality.

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
12. [Bringing Photos picker to your SwiftUI app](https://developer.apple.com/documentation/photokit/bringing-photos-picker-to-your-swiftui-app)
13. [`ButtonRole`](https://developer.apple.com/documentation/swiftui/buttonrole), including [confirm](https://developer.apple.com/documentation/swiftui/buttonrole/confirm)
14. [`NavigationTransition.zoom(sourceID:in:)`](https://developer.apple.com/documentation/swiftui/navigationtransition/zoom(sourceid:in:))
15. [`UIFontDescriptor.SystemDesign.serif`](https://developer.apple.com/documentation/uikit/uifontdescriptor/systemdesign/serif), [`Font.Design.rounded`](https://developer.apple.com/documentation/swiftui/font/design/rounded), and [Apple platform fonts](https://developer.apple.com/fonts/)
16. [WebKit platform font keywords](https://webkit.org/blog/10247/new-webkit-features-in-safari-13-1/)
17. [`UIGlassEffect`](https://developer.apple.com/documentation/uikit/uiglasseffect)
