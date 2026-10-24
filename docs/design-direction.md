# GistPad Native: design direction

**Implementation direction, October 24, 2026. Owner: Designer.** Following the user's overnight instruction to continue through M4, this is the direction for that work, with Designer reviewing the actual surfaces as they land. It replaces the accumulated Library, palette and decorative proposals. It is not a claim that the current app passes review. The safety and content contracts in [design-system.md](design-system.md) remain separate.

## The direction: a lively library, an excellent writing instrument

GistPad should feel personal before a note opens and exceptionally composed once it does. The original notebook icon supplies the identity. A date-led Today, recognizable pinned notes, the user's colored tags and a deliberate reading hierarchy give that identity substance inside the app. Native controls supply the movement, depth and familiar behavior.

The opening composition has three clear speeds: **Today invites, Pinned recognizes, Notes scans.** Opening a page is immediate and stable. Reading feels like a finished document, not an editor with its controls removed. Editing puts the caret and useful tools exactly where they belong. Unfolding reveals more context around the same page.

This is not a web workbench squeezed into iOS. It is also not a sparse prototype made "native" by putting everything in a List. The distinguishing craft is the connected experience: finding a familiar note, opening at the right place, writing immediately, and returning without losing context.

### Four principles

1. **Make importance visible.** Today, bookmarks and the full collection need different compositions, not merely different section labels. Inside a document, hierarchy comes from type and rhythm.
2. **Be immediate, then be continuous.** Cached content, a ready caret and a stable passage matter more than a clever transition. Never show the wrong note, restart the editor or animate before accepting input.
3. **Keep power direct and contextual.** Search, Create, Edit/Preview and file switching are first-class. Secondary tools stay discoverable in the place they affect, not in a permanent command dashboard.
4. **Have personality without decorating the user's words.** Use the original icon, an expressive date, personal accent, existing tag colors and precise feedback. No invented emoji covers, stationery textures, rainbow code or glass prose.

## One adaptive notebook

**The notebook home is titled GistPad.** The user's October 24 home-screen request supersedes "Library" as its visible title. Keep the existing native title chevron and menu contents. The default home contains Today, **Pinned Gists** and **Your Gists**. Scoped collections such as Daily Notes, Starred and Archive keep useful scope titles. A native collection picker at the title exposes the existing choices with the current one checked. Collection and tag filtering must be reachable without scrolling past the whole notebook. Search and Compose remain direct toolbar actions. Settings lives in the home menu. "Library" can remain the internal navigation concept, not the default screen title.

These are views into one notebook, not four activities that require a permanent tab bar. On a wide layout, the same Library becomes the native leading pane. A narrow sidebar uses compact featured rows rather than miniature two-column cards. Selection stays highlighted. [Toolbars][toolbars], [Sidebars][sidebars], [Split views][split].

In the default Library, show a pinned note once in its featured group, not again in Notes. Filtered/search results can use normal rows with a small pin indication.

Without an explicit selection, restore the last accessible page and interrupted draft for the account. Otherwise show today's existing note, or its explicit Start invitation. Never create a file on launch/unfold or leave a wide detail at a generic Select a gist message.

| Available space and task | Composition |
| --- | --- |
| Standard iPhone or compact outer display | Library pushes one page through native navigation. Edit and Preview are directly switchable |
| Unfolded with room for navigation and a useful page | Library + document. Hide/show Library uses the native sidebar affordance |
| Deliberate Split writing | Source + live Preview are the priority. Hide Library when it would squeeze either document pane |
| A genuinely roomy window | Library + Source + Preview is allowed only when both document panes remain useful after controls, margins and reserved regions |

Two document panes need at least 320 pt each, **plus** their divider and applicable reserved space at standard type. That is a lower bound, not proof of usability. Large type and the keyboard can require fewer panes. Preserve the current task when collapsing: an active edit keeps its caret and keyboard, reading does not suddenly raise a keyboard. Remember an explicit device-local view preference without forcing an unavailable Split.

**Duo is not a width breakpoint.** Apple documents asymmetric safe areas, reserved camera/folding regions, side-mounted system bars and pose-dependent layout. Do not force bars back to the top/bottom, manually redistribute their items, or claim that a resized screenshot proves a fold transition. Keep document controls with the document and Library controls with Library. [Duo HIG][duo].

The current shell establishes native sidebar collapse and retained editor/preview identity, not verified reserved-region handling for all three panes. `ArrangementView` is public from iOS 27.1, but its overview explicitly warns against nesting with navigation/layout containers. Do not prescribe it as a drop-in inside the current detail. The final root composition needs an engineering decision and actual Closed, Partially Open and Open evidence. Defaulting to two useful panes on Duo is preferable to prematurely approving three. [ArrangementView][arrangement].

## One visual language

**Three layers, each with a job.** Library uses the semantic grouped canvas with opaque, clearly separated content surfaces. Reading and source use an uninterrupted semantic page. Native Liquid Glass belongs to navigation, menus and the small floating editing accessory. No glass note cards, translucent paragraphs, custom fog overlays or glass-on-glass.

**Type is expressive in specific places.** SF supplies all interface text, prose and rendered headings. The user's October 24 morning direction supersedes the earlier New York H1/H2 treatment: use system sans throughout the reading page, with quiet rules below H1/H2 and the web reference's more generous rhythm. The Today day numeral uses system Rounded, about 44 pt at standard type. Code uses scaled system monospace. Use Dynamic Type and language fallback throughout, not fixed font names. [Typography][typography].

**Density has a rhythm.** Use 4/8/12/16/24/32-pt relationships, with 20-pt outer content margins as the normal compact starting point. Keep 32 pt between major Library sections and 8 pt between a section heading and its content. Internal spacing is smaller than the gap between sections. Controls have at least 44-pt targets, but a control's target is not an instruction to add another 44-pt container around it.

**Shapes are related, not identical.** Featured content can use a softly rounded continuous container, around 20 pt with 16-20 pt inner space. Ordinary notes share one inset-grouped list surface. Tags retain their existing smaller rounded labels. System controls own their capsule geometry and concentricity. No heavy shadows, imitation bindings or an outline around every row. [New design system][new-system].

### Color: personal content, neutral controls

**Use a valid saved profile `accentColor`. Use GistPad sky `#0EA5E9` when it is absent.** A stored yellow value is still a saved choice. Do not reinterpret it as missing merely because the web's default is yellow. The original blue icon stays unchanged.

This is based on the real contract in `gistpad.dev/src/features/account/queries.tsx`: the web declares `accentColor`, defaults it to `#facc15`, and saves preference changes to Supabase user metadata. Native preserves that key in `Packages/GistPadSync/Sources/GistPadSync/Preferences.swift` and derives readable appearance roles from it. A fixed native yellow or blue theme is not profile support.

**The user's October 24 accent-restraint request supersedes personal tint on actions, navigation, selection and the caret.** The personal accent is an allowlist, not the app-wide interaction color: Today date treatment, Today task progress and its in-content Start invitation, authored Preview numbers/bullets and existing Preview task checkboxes, plus the actual preference swatch. These small, content-related uses make the notebook personal without making every command compete for attention. Other note progress, pin metadata and selected Library surfaces are neutral. Changing the preference must not change toolbar, menu, sheet or keyboard-tool colors.

Neutral does not mean faint. Enabled commands use primary adaptive foreground, while secondary foreground is for metadata and genuine progress descriptions. Use semantic `.primary` / `UIColor.label` as the neutral role through native control APIs, allowing Liquid Glass to own its material, vibrancy and contrasting foreground. Do not freeze it to black/white, reduce its opacity or draw a replacement glass treatment. Disabled controls keep the native disabled state. Destructive commands keep their system role and red, never the personal accent. Archive is not destructive. [Color][color], [Toolbars][toolbars], [Buttons][buttons].

#### Exact surface roles for the neutral-chrome pass

| Surface | Role and retained behavior |
| --- | --- |
| Navigation and top/bottom toolbars | Back, Library/sidebar, Search, Compose, More, Share, Files, manual Save and status/recovery buttons use native monochrome primary foreground. The title/filename chevron stays neutral. Neither symbols nor glass backgrounds receive the saved accent |
| Edit / Split / Preview | Use `square.and.pencil` for Edit and the simple `eye` for Preview, with unchanged `rectangle.split.2x1` for Split. The two main symbols should differ by silhouette, not tiny details inside a document. Keep exact accessibility names and native neutral selected state. Preserve single glass and the scaled 48-pt segment floor. The whole control keeps its intrinsic width and cannot compress for a long title: the title truncates first. No personal selected segment, accent outline or shrunken symbol |
| Menus and context menus | Native primary labels/symbols/checkmarks, with system disabled states and destructive red. Pin/Star use their existing filled state and changing labels, not personal color |
| Swipe actions | Non-destructive actions, including Pin/Unpin, Archive/Unarchive and Edit Tag, use explicit `UIColor.darkGray` fills with native white on-fill glyphs/text, not inherited `.primary` or personal tint. The nominal pairing is 7.46:1; verify the actual rendered pair in both appearances and Increased Contrast. `systemGray` with white ink is not acceptable: the native captures measured 3.26:1 normally and 2.21:1 in Dark Increased Contrast. Keep their distinct symbols and action names. Delete remains system destructive red. Do not introduce orange for Pin: organization does not need another accent or imply urgency. Preserve native swipe behavior, target sizes and confirmation-before-removal |
| Sheet chrome and confirmations | Settings, Tags, Photos, accounts, file/rename/link sheets and Add to Today use neutral Close/Cancel/Add/Save controls. A single committing action may retain native prominent styling with a neutral tint and a system-contrasting label. Do not flatten the hierarchy or paint primary ink over a primary-filled button. Native alerts own their role colors, including Cancel |
| Keyboard accessory | Aa, Lists, Insert, Intelligence, Hide Keyboard and any expanded Bold/Italic targets use primary monochrome ink on the existing native glass. Their menus follow the same rule. No colored sparkles, extra capsule or geometry change |
| Intelligence sheet | Neutral Ask/Edit/Review picker and action-menu fallback, prompt controls, Generate/Try Again/Apply, citations and Close. Keep Generate/Apply prominent when appropriate, but without personal fill or ink. Progress is native secondary, not an accent animation |
| Intelligence diff | Unchanged text uses primary. Added words use primary semibold plus an underline. Removed words use secondary plus strikethrough. Retain Before/After labels and real changed-word runs, so no color is needed and no new green/red palette is introduced |
| Source caret and text selection | Restore standard UIKit text-interaction blue, independent of neutral navigation tint and saved accent. Keep native selection handles/highlight. Do not make the caret label-black/white or use a personal selected-surface fill. Apply the same separation to search and sheet text-entry controls |
| Source links and tasks | Keep the accepted source syntax palette and underlined link/destination treatment. Unchecked task syntax uses the existing `SourceSyntaxColor.orderedMarker` blue, checked task syntax retains muted ink. No source token follows the personal accent |
| Library/sidebar selection | Preserve native selected-row behavior and accessibility traits, with a neutral selected surface rather than a personal wash. Featured selected cards use the corresponding semantic neutral selection fill. Keep their text readable in the actual selected state. Pin metadata uses secondary ink |
| Tags | Metadata pills use their own tinted background and primary text, without an internal color dot. Standalone tag-picker rows retain one color swatch on an untinted row. Selected checkmarks and New Tag/Edit actions use primary neutral ink, not the tag color or personal accent. Keep selected traits, labels and existing targets |
| Photos and recovery | Summary photo symbol, disclosure chevron, More and Retry/Reconnect/Insert Here/Choose Another use neutral primary ink. Native progress and status descriptions use their semantic secondary role. Keep explicit failure symbols, readable guidance and destructive Remove role |
| Today and quick capture | Keep the accent on the Today date area, its own task progress and in-page Start action. Scope that tint to content, never the whole Today navigation container. Add to Today is a system-style capture sheet, so its glass controls and Text/Task picker remain neutral |
| Preview and external links | Keep the approved personal authored list markers and existing content task-checkbox appearance. Prose, rules, Contents controls and links are not newly accented. External links retain their underlined semantic link treatment |
| Settings and system surfaces | The accent picker shows the real chosen swatch, not a themed Settings page. Switches keep native on/off colors and state, not personal or forced monochrome tint. System share/photo/authentication/Writing Tools surfaces keep their own appearance. Existing Today widgets retain their approved content accent and system rendering modes |

Remove saved-accent inheritance from the app root, workspace/navigation containers, Library/search and sheet roots. Keep the shared account preference and native/preview trait bridge: allowed content still needs live updates. Then apply neutral control roles at the actual control/container scope, while preserving text-entry and switch defaults. Do not replace a global accent with a global foreground override that also recolors tags, links, syntax, destructive actions or native input. Coordinate `DocumentSession` appearance-only changes with its current front-matter/navigation owner.

**Acceptance:** inspect Light/Dark Library, a real note and its open More menu, then Settings, selected Tags, keyboard tools, Intelligence including a marked diff, and Photos recovery. Show that two distinct saved accents, including yellow, change Today/Preview markers but not the chrome. Include selected/disabled states and Increased Contrast. Text entry must retain a visible native caret/selection, switches their state, destructive actions red, and all existing targets/navigation behavior. A flat-color test is not a substitute for the material in context.

#### Apple comparison and evidence boundary

Apple's current iOS 27 guide images show the intended separation. **Notes** has neutral Back/Share/More and bottom editing controls beside colored tags and authored drawing. **Reminders** has neutral Back/More/Search while its Flagged title, flags and one Add action carry orange. **Journal** has neutral Back/Search/More while entry media and one Add action carry color. The shared lesson is quiet navigation, meaningful content color and, when needed, one focal action, not an app-wide tint over every icon. GistPad deliberately goes further for this user's preference: even its prominent chrome actions are neutral. [Notes writing][notes-writing], [Reminders][reminders], [Journal][journal].

These are inspected Apple-published guide images, not a hands-on claim about all states on iOS 27.1 or Duo. The HIG explicitly says small Liquid Glass controls are monochromatic by default, recommends sparse color for genuine emphasis, and recommends reducing tinted toolbar controls. Notes' colored Done example also confirms that neutral navigation is not a claim that Apple never uses a colored primary action. [Color][color], [Toolbars][toolbars].

Derive one shared native/preview role set from the saved RGB value:

| Role | Rule across Light / Dark / Light Increased / Dark Increased |
| --- | --- |
| `accentText` | Start with the saved color. Find the smallest mix toward black in Light, or white in Dark, that reaches 4.5:1 against the resolved opaque surfaces where it is used. Increased Contrast targets 7:1. Derive each appearance independently |
| `accentFill` + `onAccent` | Prefer the original opaque fill. Choose black or white foreground by greater contrast. If that pair misses the appearance's text target, minimally adjust the fill toward black or white and choose the nearer passing pair. Do not assume white text works |
| `selectedSurface` | Keep the restrained accent-tinted surface for the Today date treatment. It is no longer the Library/sidebar selection role. Check the final ink/background contrast |
| System material controls | Use native monochrome adaptation and neutral semantic tint where necessary, not any personal accent role. Preserve role-owned destructive/disabled/confirmation behavior and evaluate the actual material in context |

Use WCAG relative luminance/contrast on final composited colors, not HSB brightness as a proxy. Nontext affordances requiring a visible boundary need 3:1. Test yellow, white, black, saturated colors and missing/invalid values in all four appearances. Preserve the stored hex; readability adaptation must not rewrite the account preference. Invalid data keeps a native fallback and an explicit Settings explanation, not a silent metadata repair. [Color][color], [Adoption][adoption].

This replaces the old fixed-accent proposal. Appearance changes update attributes/colors only, never source bytes, selection, scroll or Undo. Settings offers one opacity-free color control backed by the same profile field, not a new independent native theme system.

## Surface decisions

| Surface | Composition and interaction | Native pattern and reason |
| --- | --- | --- |
| **Library** | Home title GistPad, sections Pinned Gists and Your Gists. Notes use headline titles, an optional clean cached excerpt and one subordinate metadata group for tags/time/file count. No placeholder excerpts or network fetches for decoration. Ordinary rows have inset separators and content-driven height | Native navigation, collection picker, searchable list, swipe/context actions. Recognition and comfortable scanning, rather than either a dense web tree or huge isolated cards |
| **Today** | One compact date-led feature using the two-column composition below: date at leading, useful title/status/excerpt content beside it. Use the existing accent-tinted date area, not an illustrated cover. Leave real space before Pinned Gists. Existing Today opens directly. Start opens Edit with the caret at the end | One featured content button, not nested controls. Real date and task state earn the space. No automatic creation on appearance, streaks, fabricated tasks or "Earlier days" carryover |
| **Pinned** | A distinct featured group, not the ordinary list with a pin header. Use content cards when at least two readable cards fit: minimum 156-pt card width and 12-pt gaps. Exact title, one useful excerpt and existing labels. No repeated recency line, fake cover, extracted emoji, colored binding or fixed card height. Narrow/AX/sidebar layouts use full-width featured rows | Adaptive collection with ordinary selection and context actions. Pinned is a small set of deliberate destinations, so it earns more visual weight than the scan list |
| **Daily Notes / Starred / Archive** | Dedicated, titled collection views using the same row language. Daily files are navigable newest first. Archive is visually ordinary, not dimmed or treated as deleted. A clear restore action and truthful empty state | Native collection navigation and lists. These are useful retrieval paths, not extra dashboards |
| **Reading** | A composed page with the metrics below, deliberate heading contrast and no healthy-state footer. Render the user's actual headings and emoji. Do not inject the note description as another giant heading | Native scroll container behavior around offline bundled WebKit content. Reading should not look like a web panel, despite the rendering implementation |
| **Editing** | One retained native text view. Clear Markdown structure: purple emphasis/headings in Dark, green quotes, meaningful blue numbers/links, and monochrome code. Preserve the source characters. Edit/Preview keeps the relevant passage and previous selection rather than repeatedly jumping to the beginning | Native text selection, Undo, Find, Writing Tools, composition and keyboard behavior. Color assists structure, not language-rainbow decoration |
| **Split** | Same draft and document session in Source and live Preview. No duplicate pending-photo shelf or second save state. Thin divider; no separate "preview card." Show Edit / Split / Preview directly when eligible | Native mode control and adaptive pane arrangement. Split is a writing tool, not a new navigation root or another copy of the document |
| **Keyboard tools** | One native interactive glass capsule with space around it and 12-pt separation from the keyboard. Six direct targets: Aa, Bold, Italic, Lists, Insert, Hide Keyboard. Dismissal is always visible. On genuinely constrained layouts, fold Bold/Italic into Aa before shrinking targets or hiding dismissal | `UIGlassEffect`, native buttons and anchored menus. Do not depend on toolbar overflow to hide an essential escape. Find remains a note command and Command-F |
| **Tags** | Keep tinted metadata pills, full names and user colors, but remove their redundant inner dots. The picker is one compact searchable list: standalone swatch, neutral name/check, minimum 44-pt total rows and one scope footer. Remove the duplicate "On this note" shelf, "All tags" heading and enclosing group cards. Editing is a swipe/context/named accessibility action | Native sheet/list/search, medium/large detents, initially large at AX sizes. Metadata can be colorful without making the management surface bulky |
| **Search** | Direct native toolbar Search, immediate typing and one normal result list. Show current collection/tag scope and allow broadening. Reuse recognizable title/snippet/labels, not a second card design. Describe exact title/filename/tag scope and cached-content coverage; do not imply a full-text index that does not exist | System searchable presentation, suggestions/scopes where supported. No extra Search tab for this single-notebook app and no custom floating search panel. [Search fields][search] |
| **Settings** | A small native Form: account, writing behavior, saved accent and relevant appearance options. No hero, dashboard or decorative grouped cards inside grouped cards. Destructive account actions isolated. Label the writing toggle Autosave While Writing and explain background saving once in its footer | Familiar settings hierarchy. The current web-parity saving decision belongs to product behavior, not a design-created sync system. Preference copy must describe the actual triggers |
| **Intelligence** | Native Writing Tools is the current capability. V1 also includes exactly three approved whole-note actions: Ask, Edit and Review, using the surface below. No tag suggestions, selection/section modes, inactive placeholder button, assistant rail or separate global chatbot destination | Apple Intelligence as a writing capability, not a competing product inside the notebook |

### Tag labels: one color treatment, not two

**Remove the dot inside tag pills.** Their tinted background already carries the tag's color. A second saturated circle repeats that information, consumes useful name width and makes a metadata line busier. The complete name identifies the tag, including tags with similar hues; neither the fill nor a dot can substitute for that non-color identity. Keep the scaled footnote-medium primary label, existing 8-pt horizontal/4-pt vertical padding, 8-pt corners, tint strength and honest overflow behavior. Apply the same dot-free pill to home rows, featured cards, note metadata and selected filter tokens. A selected pill may retain its neutral checkmark.

**Keep the dot in picker rows.** Filter by tags and the tag editor use untinted native rows, so one standalone swatch is useful there. Names, selection checks and Done/Save/Close are primary adaptive ink. The swatch is the only tag-colored part of the row; do not tint the row, name or confirmation action. This is the same information hierarchy in a different native container, not a competing chip style.

Check the final primary-text/tinted-fill pair in Light/Dark and Increased Contrast, including white, black, yellow, missing-color and similar-hue tags. Keep 4.5:1 text contrast normally and 7:1 in Increased Contrast. Preserve full names, wrapping/AX growth and selected accessibility traits. Removing a dot must not reduce a row's target or create an unlabeled color-only control. The change is deliberately limited to redundant pill decoration; it does not redesign the palette or picker.

### Home: use the space for the person's day

**Bring the useful words beside the date, not underneath an almost-empty header.** Keep the Today card's existing semantic surface, 20-pt internal padding and date tile. At standard type, use two columns separated by 16 pt: the date tile at leading, and a flexible content column. In that content column, Today/weekday is at upper leading, real task state at upper trailing, and a clean excerpt spans the column below with 8-12 pt separation. This replaces both the full-width raw excerpt below the date and the duplicated bottom progress row. Let actual content determine height. Do not add an illustration, streak, greeting, quick-action grid or stretched decorative date.

At the shown folded measure, the existing roughly 80-pt date tile leaves about 200 pt for useful content inside the card. Use up to two lines of the actual cached excerpt there. At wider home widths, the excerpt gains a comfortable measure rather than an extra dashboard column. On an unfolded layout the card remains in the actual leading pane, never steals document space, and responds to that pane's usable width. Use the two-column form only when its intrinsic content fits, with about 280 pt of inner measure as the standard-size starting point. In a narrow sidebar or accessibility category, use the compact Today/date heading, full-width excerpt and a wrapping text task summary instead of squeezing the date tile or capping type. These are composition criteria, not a claimed physical-Duo test.

| Today state | Compact task presentation |
| --- | --- |
| Known tasks, some incomplete | Upper-trailing 32-pt determinate completion ring, with remaining count at its center and a small "left" caption. The accessible value states completed, total and remaining. At zero complete, the count still distinguishes an empty track from loading |
| All known tasks complete | Replace the hollow ring with a filled accent disc and contrasting checkmark, with "All done" beside/below as space permits. Do not show an empty-looking donut or repeat a second "1 of 1" row |
| No tasks or no trustworthy count | Omit the entire progress area, not a zero ring, placeholder count or loading ring. The excerpt takes that width. Keep an honest short card when there is little content |
| Today's note absent | Keep the date and a concise Start today's note invitation in the content column. The whole card starts the note. No fabricated excerpt or completion state |

The progress indicator is informational, not another button. The whole Today card remains one accessible opening action whose value contains the date and real task summary. Keep the current one-shot feedback after committed task changes. Do not animate a full completion celebration on home refresh.

**Excerpts are readable text derived from cached source, never raw Markdown.** Use one extraction contract for Today, pinned cards and ordinary rows. Parse before applying the excerpt limit, so long YAML cannot consume the snippet budget. Skip a complete leading front-matter block and its following empty lines, the document-title heading/date-template header, and nonprose blocks such as code/Mermaid. Preserve meaningful prose/task words, emoji and link labels while removing heading/list/task delimiters, emphasis syntax, destinations and HTML tags. Retain visible text inside inline HTML such as `<ins>`. Do not remove mid-document `---` as though it were metadata, expose an unclosed metadata-looking prefix as clean prose, or fetch content merely to fill a card. If nothing useful remains, omit the excerpt and use the existing factual metadata. Do not invent a summary. Reuse the same helper before each surface's existing length/line limit, and update it from the current local draft as well as cache.

**Routine refresh is a small trailing footer indicator, not a message row.** Remove the visible "Updating from GitHub" section. Home and notes share the native footer-status slot specified below. Pull-to-refresh keeps its native indicator rather than adding a duplicate. With no cache, do not announce an empty notebook while the initial request is still pending. This changes presentation, not the sync contract.

Acceptance includes GistPad and both exact section titles, folded/narrow-sidebar/wide composition, Large/AX text, no-task/partial/complete/missing Today states, long YAML and title-only notes, readable task/HTML/link excerpts, and idle/refresh/error transitions. The user's green Compose icon is covered by the neutral-chrome policy, not a new home accent exception.

### Shared footer status: quiet until something needs you

**One native status slot serves home and the open note.** Place it at the trailing footer-toolbar position, in the same native control layer as home Search. Search remains available. Let the system move the toolbar to Duo's rail; do not place a fixed bottom-right overlay, add another bar background or guess the camera/rail inset. The status must not reserve a document-height banner, shift the reading anchor or steal keyboard focus. Home and notes use the same component/state vocabulary, not independent spinner and error designs.

**The writing keyboard may defer nonblocking GitHub status.** When it covers the native footer slot, let that status item yield instead of moving it into the keyboard accessory, floating it above the keyboard or dismissing input. A covered control must leave accessibility traversal and hit testing, not remain as an unreachable VoiceOver stop. Preserve the actual problem while hidden and restore it when the keyboard dismisses, without requiring a new check or treating dismissal as recovery. A native rail item that remains genuinely visible can keep its native placement and target; do not force an invisible duplicate. This exception applies only to routine checks and remote-connection status with the existing local-safety protections. Local-save failure, uncertain publication and conflict notices retain their explicit behavior above the keyboard.

| State | Presentation and behavior |
| --- | --- |
| Healthy idle | No status item, success check, cloud badge, timestamp or empty status bar |
| Genuine background check/retry | One small native circular spinner with secondary neutral ink, no visible text or glass button. Delay appearance by 350 ms to avoid a flash; cancel the delay when the operation ends or is superseded. No minimum hold. Accessibility names the actual operation, such as "Checking GitHub" or "Saving to GitHub", never a false generic "Syncing" |
| Cancellation, superseded/stale check, one-off network failure | No error button, banner, toast or warning announcement. The sync owner handles bounded quiet retry/backoff and determines persistent failure. A delay alone is not proof of an actionable error |
| Persistent actionable GitHub problem | One standard native glass button containing the simple `exclamationmark` symbol, primary adaptive monochrome ink and at least a 44-pt target. No personal accent, yellow/red warning disc, nested outlined-circle symbol or attention-seeking pulse. The accessible label is "GitHub needs attention", with the actual friendly reason as its value and "Shows details and recovery actions" as its hint |

Tapping the problem button opens an anchored native popover where useful, adapting to a sheet on compact layouts and growing for accessibility text. Title it **GitHub status**. Show a concise operation-specific heading and explanation, then one appropriate primary recovery action and native Close. A failed background inspection says **Couldn't check for updates**, not "Couldn't sync". A failed publication says **Changes haven't reached GitHub**. State **Your changes are saved on this iPhone** only when durable local saving is verified; an inspection-only problem can instead say **Your notes on this iPhone are unchanged**. Do not expose raw errors, stale-review internals or speculative safety claims.

Use **Retry** for a retryable persistent connection problem, **Reconnect GitHub** for authentication, the actual retry time for a rate limit, and **Review Changes** to open the existing conflict flow. Do not suggest that Retry resolves a conflict, or that reconnecting publishes anything. While recovery runs, prevent duplicate requests and show native progress in that surface. Clear the problem only on actual success or a genuinely superseding state, not merely because Retry was tapped. On success, dismiss the resolved explanation without a second confirmation. On failure, keep the explanation and current recovery action available.

There is one slot even when several operations have problems. Show the most consequential actionable state and identify the affected operation in its explanation, rather than stacking status buttons. Never let a background spinner overwrite an unresolved problem. Do not repeatedly announce a persistent state or move VoiceOver focus as polling changes.

**Quiet presentation is not permission to conceal data risk.** Local persistence failure, uncertain publication and an active conflict decision retain their existing explicit recovery, source protections and blocking rules. First-load failures without useful cached content retain the honest page-level recovery state. The small status control replaces routine remote-check/connection banners, not those safety surfaces.

Acceptance covers transient failure then success with no warning, navigation cancellation, a persistent inspection failure, auth/rate-limit recovery, Retry failing again, successful recovery, conflict routing and local-save failure remaining explicit. Inspect the real footer/rail and open explanation in Light/Dark, AX and Increased Contrast, including a visible keyboard and a long scrolled note. With the footer covered, prove the item is absent from accessibility traversal, the problem survives and the control returns after keyboard dismissal; safety notices remain available. A visible control must be actionable. Retry and the status transition must preserve the writing position, native caret, selection and selected file; a raw TextKit content offset alone is not a reliable proxy for the visible position. [Color][color], [Toolbars][toolbars], [Buttons][buttons], [Progress indicators][progress].

### The reading page, precisely

The current screenshots fail first on **where the page starts**, then on composition. Content may pass under native controls while scrolling, but the first heading must be below them at rest. Soft scroll edges are a consequence of real underlap, not permission to hide the beginning of the note.

| Element | Starting metric at standard type |
| --- | --- |
| Measure | Full useful compact width minus a single 20-pt gutter on each side, capped at 64ch on wider pages. A narrow split pane may use 16 pt. Never stack native and CSS gutters |
| Page start/end | 24 pt after the unobscured top boundary. At least 40 pt of page breathing room at the end, with native bottom inset additionally keeping the last line above actual controls |
| Body | SF, 17-pt body reference, 1.75-em leading and 1.25-em paragraph gaps. Scale with resolved native metrics |
| H1 | System sans bold, 34 pt at Large, growing along the native Large Title curve rather than staying twice Body at every category. No top margin when first. A quiet semantic separator spans the text measure below the heading, with 1rem of padding above the rule |
| H2 | System sans semibold, 25.5 pt at Large, growing along the native Title 2 curve. About 3rem before a new section, except at the page start. The same padded separator treatment as H1 |
| H3 and lower | System sans, H3 at 21.25 pt at Large, growing along the native Title 3 curve. Preserve the lower-heading hierarchy without adding rules to every level |
| Lists/tasks | A clear marker gutter, consistent wrapped-line alignment and 0.5-em gaps between items, still tighter than the section rhythm. Authored numbers and bullets use personal `accentText`, with ordinary marker weight and normal item ink. Task targets remain at least 44 pt without dimming read-only labels |
| Code/tables | Scaled monospace and quiet opaque surfaces. Horizontal overflow stays local to the code/table, never shifts the page |
| Anchors | Land the target about 16 pt below the actual unobscured top, not below an assumed browser origin |

One deliberate native preview adaptation is proposed: an authored/generated table-of-contents module starts as a compact **Contents disclosure**, rather than a large expanded card occupying the opening screen. Its expanded links keep usable targets. Never inject it into a note that did not request it, and do not change the authored open state of ordinary HTML details. The module label uses ordinary SF interface hierarchy, not the larger authored-heading treatment.

The Large references and spacing follow the user's web reference and `gistpad.dev/src/features/markdown/index.css`, not a fixed desktop pixel size. At Large, H1/H2/H3 retain the approved 2/1.5/1.25 Body relationships. At other categories, measure each corresponding native text style with `UIFont.preferredFont` and add its exact point growth from Large to the approved heading reference. This means native Large Title for H1, native Title 2 plus a constant 3.5 pt for H2, and native Title 3 plus a constant 1.25 pt for H3. Do not multiply the native heading sizes by a calibration ratio, which can let H2 overtake H1 at the largest categories. Send those resolved sizes to the preview rather than multiplying its scaled Body by a fixed heading ratio. This preserves the approved standard appearance while letting the hierarchy narrow naturally at accessibility sizes, without capping Dynamic Type or hand-tuned clamps. This corrects the earlier fixed-ratio AX acceptance.

Here `rem` follows the native-scaled body reference. H1/H2 rules are one CSS pixel, resolved from the semantic separator role in all four appearances. They organize the document, not the navigation header. Preserve authored emoji, ordered-list starts, native accent roles, generous wrapping and the existing safe-area contract. Prefer normal whole-word wrapping. Emergency wrapping is only for a single word wider than its column, never a reason to accept an isolated final letter at full width when the native heading curve avoids it. Review README headings at AX3 and AX5 as well as Large. [Typography][typography].

The user's request for colored list markers uses the existing `--gp-accent-text` role, not the raw saved color, added opacity or a new pastel palette. Its small area supplies restrained personality while meeting 4.5:1 normally and 7:1 with Increased Contrast. Apply it to authored ordered/unordered list markers, including nesting. Keep numbering, marker-to-text separation and wrapped alignment intact. Do not recolor item text, task checkboxes, generated Contents or Source syntax as part of this treatment.

Keep native bounce and responsive scrolling. One soft edge treatment per pane where controls actually overlap. No CSS masks, painted gradients, hard content cutoff above a nonexistent footer, doubled safe areas or scroll reset on each source generation. Preview refresh must preserve the current passage. [Materials][materials], [New design system][new-system].

### Menus: make object scope obvious

**The title cluster is for file navigation, not miscellaneous actions.** On a multi-file note, identify the note and show the exact selected filename as the subtitle, except when the selected filename is `README.md` in any case. Then show only the note title while retaining the file menu and its chevron. For other filenames, add a 4-pt body-scaled gap above the native subtitle rather than squeezing it against the title. Its native menu lists files directly with the current file checked, then a separate file-management group: **Rename Current File...** and **Add File...**. Daily files retain newest-first date grouping.

**Rename Note... belongs in the note's More menu.** The same visible menu must not offer an ambiguous Rename and Rename File with identical pencils. This fixes information architecture, not just the choice of symbol. For a single-file note, omit an unnecessary title chevron; Files remains available in More for management.

More starts with a compact Pin / Star / Share / Copy Link group. Then note/content commands: Rename Note, Tags, Files, Find and the applicable sidebar command. Open in GitHub is separate. Archive follows, with destructive Delete isolated last. Direct mode controls stay outside More. Use real native sections and purposeful symbols, not disabled headings, ornamental separators or a different icon merely to fill every row. [Menus][menus], [Toolbars][toolbars].

### Intelligence has a place, not a new workbench

**V1 has exactly three app-owned actions: Ask, Edit and Review, all on the entire note.** System Writing Tools remains the selection-based capability. There are no custom selection/section actions or tag suggestions. Following the user's later October 24 decision, skip Private Cloud Compute. This is the surface to implement and review, not a claim that the custom engine already ships.

With these actions, the compact keyboard capsule becomes **Aa / Lists / Insert / Intelligence / Hide Keyboard**. Bold and Italic move into Aa; on a sufficiently wide surface they can reappear as direct targets. Do not bolt a seventh control onto the current compact bar. Intelligence uses a labeled `sparkles` action in the same control language, not a persistent multicolor orb. It is also reachable from the note's menu in Preview.

The surface identifies the note and exact filename before the request, with a quiet **On device** context label, never a model-name or token-budget display. Whole-note scope includes all text of the open file, never a silently truncated passage or unrelated daily files/templates. There is no scope picker. Retain source selection and scroll while open and return to the same passage when dismissed. It grows to a large sheet for review, or a system popover when appropriate, not an always-present third pane.

Use a native three-action picker in this same surface, not an introductory dashboard. Ask is the initial action. Ask/Edit provides a focused prompt field; Review has one clear Generate action. Request, progress, cancellation and result stay in the same sheet. A compact diff stacks labeled Before/After hunks; a wide review can show them side by side. Added/deleted meaning must survive without color.

**Waiting for a validated answer is an explicit state, not an empty result.** Show the existing small native circular `ProgressView` and secondary Dynamic Type callout as soon as generation starts. Keep the submitted request and an enabled neutral Cancel action. Use the actual engine phase: Preparing this note, Answering, or real numbered parts. Keep the pending group visible in the sheet's usable viewport, including at AX sizes. No empty answer bubble, shimmering placeholder, simulated typing, accent animation, invented percentage or timed slogan is needed. Native indeterminate progress remains the treatment with Reduce Motion; do not repeatedly announce spinner updates.

At accessibility sizes, the submitted question wraps fully in the existing scroll view instead of inheriting the standard two-line echo limit. Keep phase and Cancel ahead of a long echo when needed, so the full request does not push cancellation out of the initial viewport. Do not shrink type or add a new floating control to achieve this. Align the action menu's visible Ask/Edit/Review label with the filename and request at the shared leading content edge while preserving its native target.

Ask may hold the entire answer until its prose and citations validate. Keep the same live progress surface through a bounded quality retry, without briefly revealing rejected text, resetting the sheet or suggesting the note has changed. Progressive reveal is optional and may show only already-validated content. Native acceptance must include at least five seconds with **zero answer parts**, cancellation, successful replacement by the answer and a final failure that preserves the request. Measure request-to-first-visible-validated-answer p50/p90 with all preparation and quality retries included, not hidden first-token time. Source review alone does not establish that the pending state remains visible on the actual sheet.

| Action | Result and commitment |
| --- | --- |
| Ask | A validated answer about the whole note, with a way back to referenced source passages. Progressive reveal is optional; quotes must match the snapshot. No source mutation or global chat destination |
| Edit | Changes across the whole note presented as one reviewable diff. Apply the accepted set as one transaction and one Undo step |
| Review | Whole-note comments anchored to exact source quotes, with optional replacements the user can apply individually. Comments remain separate from source until Apply |

**Ask answer addendum (October 24): a short lead, then zero to five useful points.** A direct question may need only its lead. Do not pad it with five generic observations. Render validated structured fields as native SwiftUI text rows inside the existing scroll view, not Markdown, a nested scrolling List, another card or a chat bubble.

- **Type:** lead is system `.body.weight(.semibold)`, points are `.body` regular, both primary adaptive ink. Body is 17 pt at Large and follows its native Dynamic Type curve. Use normal system leading, selectable text and no extra Answer heading. [Typography][typography].
- **Markers:** use a standard text bullet in the same body style, primary neutral ink, first-baseline aligned with an 8-pt gap and a hanging indent for continuation lines. The app owns markers, not generated strings. No personal accent, numbered badges, task circles or interactive row treatment. Mirror the leading layout for RTL.
- **Rhythm:** 12 pt from lead to first point and between points, within the existing 20-pt sheet gutter. No row fills or separators. Keep the existing verified citations/source actions separate, 16 pt after the answer, without changing provenance or hidden-front-matter behavior. These spacing values are product choices, not Apple-prescribed metrics.

At AX sizes, retain the same body styles and natural word wrapping, without line caps, shrinking or a capped font scale. Each point is one logical accessibility element; the decorative marker is not a separate stop. Read lead, points and references in order rather than combining the entire answer. Once ready, put the answer before the full AX request echo so it is not buried below a long question. The question remains fully readable afterward. Do not add typewriter/cascade animation or force-scroll while someone is reading.

First-frame acceptance covers a real lead-only answer and a real lead-plus-points answer at Large/AX3 in Light/Dark, including Increased Contrast. Confirm useful content, hanging indents and source actions, not just the new schema's shape. Rendering acceptance does not certify the model's answer quality.

Edit and Review share exact-quote replacement hunks against the captured source; do not require the model to regenerate a long note. Reject nonmatching or overlapping hunks and report the omitted count in the review. Never offer Apply for an unverified anchor. The app computes the diff, not the model.

Everything runs on device. A note that fits the measured request budget takes one pass. Longer notes use bounded passes covering every section, with final synthesis for Ask and merged anchored replacements for Edit/Review. Show honest progress such as **Reviewing part 3 of 7**, then **Preparing changes**. Say "section" only when the units are actual authored sections. Do not claim a partial pass covers the whole note. Cancellation or a failed pass never partially applies source.

If whole-note processing is unavailable, explain why. Do not quietly use an excerpt, introduce smaller-scope modes or expose token budgeting as the user's problem. Unavailability or refusal preserves the request and original note. Never fall back to another provider. Read-only notes support Ask/Review, but source Apply is unavailable with a reason. Real generation remains hardware acceptance.

Proposals never enter the source or publish before Apply. A changed account, document or unrelated source edit invalidates stale Apply and offers regeneration rather than overwriting newer work. Applying one Review comment deterministically updates the remaining verified anchors; it must not require a model rerun for every comment. Applied edits follow the normal saving policy. Availability, loading, cancellation and errors stay inside this surface, with the original note usable when it closes. No new intelligence-generated sync states or permanent dashboard.

## M4: the same notebook outside the app

These are focused entrances to Today and existing notes, not miniature copies of Library. Use native widget margins, text styles and rendering modes. Profile accent belongs in full-color presentation; system tinted, clear and StandBy night appearances retain their own treatment. Personal task/excerpt content is privacy-sensitive. [Widgets][widgets].

| Surface | Treatment |
| --- | --- |
| Small Today widget | Rounded date with Today pinned beside the numeral in every state. Place one useful task or invitation 12 pt below the calendar header, with flexible space after it. If there are no tasks, show a genuine short excerpt or Start Today, never an invented task |
| Medium Today widget | Date/count at leading, up to two readable task rows alongside. Prefer fewer rows over tiny labels/targets. Tapping the background opens Today; task controls perform the real action in place |
| Lock Screen | Rectangular: date and one legible task/check where space permits. Inline/circular: date or remaining count, opening Today rather than cramming in a checklist |
| StandBy | Adapt the small widget, emphasizing date and one useful task at distance. Let the system remove the background and apply its night treatment. No extra clock or custom glow |
| Add to Today | One `square.and.pencil` control named Add to Today. Open a native quick-capture sheet when text is needed: destination date, focused input, Text/Task choice, Cancel/Add. The shortcut accepts provided text and the same choice without redundant UI. No blank/placeholder insertion |
| Spotlight and links | Real note title, useful cached snippet and exact filename when needed. Open the target through one router, with the same immediate cached selection and truthful loading/error states as Library. Preserve a pending destination through sign-in. Never substitute Today or create a note for a missing target |

At accessibility text sizes, Small uses a compact date and the real remaining-task summary, with the whole widget opening Today. Medium retains one readable interactive task. Do not cap Dynamic Type to preserve a checkbox whose task cannot be identified. Completed task labels use secondary ink alongside the filled check.

Quick capture shows the pinned destination as a localized short date. Keep the native Add to Today navigation bar visible when the input takes focus. Text and Task use quiet, non-inserting prompts and native cancel/confirm roles. The native confirmation toolbar now uses neutral prominent styling with the system's contrasting foreground, not either personal accent role. Cancellation stays neutral. At accessibility sizes, the kind picker becomes a labeled native menu on one baseline, with at least two scaled writing lines kept above the keyboard. Accessibility and failure presentations use the large detent. Failure dismisses the keyboard, puts the semantic error before the retained input and keeps Add available to retry. Local-save failure explicitly reassures that the text is still here. Other errors use the shared friendly mapping, never raw red diagnostics.

Interactive checks bind to the displayed date/file and task anchor, never a row index in whichever note is now open. A stale task is not modified and offers Open Today. Locked-device interaction follows system authentication. Missing account/content gets a clear sign-in/open invitation; timeline refresh never creates a note. Widget/control mutations use existing durable-draft behavior, not a separate publication path. [Widget interactivity][widget-interactivity], [Controls][controls].

Universal links need the website's deployed AASA association as well as the app entitlement. A prepared local file is not live link acceptance. Keep the browser fallback truthful until that deployment; `gistpad://` serves app-owned routes. [Associated domains][associated-domains].

## States and movement are part of the design

| Situation | Required experience |
| --- | --- |
| Existing cached note | Selected title and real content immediately. No previous-note frame, placeholder or network-dependent entrance |
| Uncached first open | Selected title and uninterrupted semantic page immediately. After 350 ms of genuine waiting, show a small native circular progress indicator and "Opening note..." in the usable detail area. No skeleton, shimmer, fabricated text or progress capsule. Show ready content immediately, with no forced hold or second entrance animation |
| Create / Today Start | Real locally durable source session, Edit, caret ready and keyboard requested on attachment. Create requires no network. Normal cached Today is immediate. If Today must discover its remote identity or required template, show that genuine pending state rather than inventing content |
| Failed read / offline without cache | Keep the selected identity, state the problem and offer Retry. Do not reveal another note or substitute an empty document that looks editable |
| Empty notebook / first run | Original notebook artwork at a modest size, a short invitation and one clear sign-in/create action. No marketing carousel. Signed-in emptiness must not look signed out |
| Empty collection / no search results | Explain this collection/query and offer the relevant create, clear-filter or broaden-search action. No generic notebook illustration masking the cause |
| Healthy saving | No footer, status pill, reserved empty bar or recurring haptic. Manual Save appears when genuinely needed. Offline pending work gets a quiet explainable icon; actionable failures get one compact notice and recovery action |
| Conflict / local failure / Photos | Preserve their explicit safety and privacy behavior. Compact native problem surfaces, not decoration. Public-image notice must remain legible above the keyboard. A pending shelf is bounded and scrollable without eliminating the writing viewport |

### Opening a note: real identity, quiet progress, then words

**Remove the skeleton, not the existing native opening transition.** A note has no predictable paragraph layout before its bytes arrive. Fake lines preview the wrong document shape and add a second visual event to a good transition. The known title and native navigation already establish where the person is.

Cached content wins: show the selected note's real available words immediately, including offline. Never replace them with a skeleton, dim them behind a spinner or wait for a network refresh before showing them. A brief handoff to the retained editor must not flash progress or an empty editable document.

For an uncached request, keep the actual page background and known native title from the first frame. If it is still pending after **350 ms**, show one system circular `ProgressView` at its regular control size, in semantic secondary ink, with **"Opening note..."** below it in Dynamic Type subheadline, also secondary, separated by 12 pt. Center that compact group inside the remaining safe-area detail viewport, not the physical display or a guessed region beside the Duo rail. Do not put it in a card, capsule, sheet or scrim, repeat the title in the body, use a custom spinner, invent percentages or add timed loading slogans.

The delay belongs to the current opening request. Cancel it on success, failure, replacement or navigation away so a late indicator or document cannot take over another destination. Back and Library navigation remain available. Do not expose editable content commands or request the keyboard before the real document session is ready. Ready content replaces progress immediately without a minimum display time, second navigation, scale, slide or deliberately delayed input.

Expose the progress as one accessible element labeled "Opening [note title]", without announcing every spinner update or stealing focus from navigation. The visible label wraps naturally at AX sizes. Native progress remains meaningful with Reduce Motion, and the app adds no shimmer, pulse or custom movement. A genuinely failed read, including offline without cache, uses the existing selected-identity recovery with **Try Again**. A slow request is not a fake error or an empty note.

Acceptance covers a cache hit with no loading flash, an uncached open completing before the delay, a delayed open, content becoming ready, failure/retry and leaving or changing notes before completion. Inspect Light/Dark, AX3, Increased Contrast and Reduce Motion. Cached/offline content, a real empty file and a pending request must remain distinguishable. The 350-ms delay and composition are GistPad decisions, not Apple-prescribed metrics. Apple's guidance supports immediate useful context, system progress for an unknown duration and continued navigation while content loads. [Loading][loading], [Progress indicators][progress].

Use the native transition from a collection into its detail, native menu/sheet presentation and the glass control's touch response. Do not put a custom cover animation ahead of a ready caret. Card zoom is optional only where its matched source remains stable and cancellation is correct. A direct task completion or pin can have one brief symbol/haptic response **after** the local action succeeds. No haptic for background saving, refresh, initial appearance or every keystroke. Reduce Motion uses the settled state without loss of meaning. [Motion][motion].

### Three signature moments

1. **Today turns a page.** The Rounded date changes with one roughly 250-ms numeric transition only when the actual day changes, not on every Library appearance. Opening uses the system transition from its stable feature source. No midnight haptic or decorative cover flip.
2. **A task lands.** After a successful local toggle, replace the circle with its check in one roughly 200-ms symbol transition and one light impact. Keep the note line in place. Widgets use supported content transitions after the intent succeeds; system feedback, not promised custom widget haptics. No confetti or success before persistence.
3. **A new page is already yours.** Compose presents the real source through native navigation, with the caret visible and keyboard requested on attachment. One soft impact acknowledges accepted local creation. No naming interstitial, delayed reveal or haptic on restoration. Input is never held for the animation.

Reduce Motion replaces the first two with their settled state. The keyboard and navigation keep system behavior.

## What we cut, and what earns approval

Cut the fake notebook covers and bindings, extracted emoji faces, solid web tag pills, additional accent systems, persistent save explanations, generalized dashboards, compulsory three-column Duo layout and decorative transition sequence. Keep the original icon, current labels, real content, strong hierarchy and useful power.

The overnight request supersedes waiting for another user review before building. Designer still reviews one connected real-app flow, not isolated styled fixtures: Library to pinned note, long reading scroll, Edit and typing, visible keyboard dismissal, file switch, Create, Today, Tags, search, Settings and the three intelligence actions. Repeat in Light/Dark, Increased Contrast, large/AX text and reduced effects. Include empty, offline and failed states. The user reviews the outcome in the morning. Actual Duo poses remain a hardware acceptance gate.

**Earlier baseline, not current whole-app sign-off.** The user's four screenshots show installed `6449375`. Interface's synthetic `73c84b6` captures confirm that changing tint alone does not fix Library hierarchy and the Tags picker still repeats large sections. The `081d35a` Light/Dark reading frames place the complete resting heading correctly; their expanded Contents block still dominates the page. The same checkpoint shows a legible Photos notice and unobscured native picker at Large. The focused Dark source frame has clear keyboard-tool separation but an unacceptable paragraph/title collision. At that checkpoint, scrolling edges, AX Photos, pending-shelf writing space, Search, Settings and open menus remained unaccepted. Those 466-pt frames have unverified posture. Later acceptance supersedes only the particular states actually reviewed.

**October 24 native follow-up accepted, within the shown scope.** Actual primary-display captures now establish the GistPad home hierarchy, useful Today columns and explicit completion, dot-free metadata pills, neutral tag management and readable Light/Dark status recovery. Corrected AX captures show the emoji title yielding to the intact mode picker and complete tag names wrapping in both appearances. Dark increased-contrast frames establish readable Tag Save, AI Apply/Try Again and a precise monochrome changed-word diff. The genuine zero-answer AX Ask frame now aligns its menu label and keeps phase/Cancel before a fully wrapping, scrollable question. Native keyboard tools stay neutral while text entry retains its system-blue caret. The canonical image evidence and individual scoped verdicts are in channel messages 1217-1271.

**Native row actions accepted, within the shown scope.** The corrected Light/Dark gist menus isolate Delete after Pin/Archive, and the GitHub confirmation points to the named target row. The cancelled-swipe frames restore that row. The twelve Closed-posture captures from `810e3b5` establish visible Archive, Pin and Edit Tag actions in Light/Dark, normally and with Increased Contrast. Their actual white/dark-gray on-fill pairs measure 7.46:1 in every supplied frame. Delete retains native destructive red. This supersedes the rejected `systemGray` recipe, not the interaction or deletion-safety gates. Evidence is in channel messages 1290 and 1306.

**Open-posture title and mode picker accepted, within the shown scope.** Eight `primary-1` captures at AX3 and 951-pt inner-display width show intact two- and three-mode controls, separate title chevrons and neutral readable states in Light/Dark. The long title truncates before the picker, while the shorter emoji title fits without taking its space. These actual frames close the wide chrome visual check alongside the reported real-control gate. The initial long-title Dark/two-mode frame was blank, but its fourteen-second settled recapture renders the full body with the same 199,184 body-ink pixels as the other Dark frames. All eight now show the expected reading content. This closes that capture-readiness check, not performance, loading or whole-renderer acceptance. Evidence is in channel messages 1313, 1318 and 1359.

This is visual acceptance of those surfaces and variants, not a waiver of real-control interaction coverage or the integrated regression. It does not establish unshown screens, spoken VoiceOver behavior, physical Duo posture/unfolding, live-model quality or the separate Rich-editor experiment. Keep those gates distinct rather than calling the whole app accepted from fixture screenshots.

## What the research changes

Apple's current design system is not a request to add blur and pills. It separates a functional control layer from content, emphasizes grouping over decoration, and makes shape, motion and navigation one system. Scroll-edge effects clarify overlap rather than act as decorative fades. [Materials][materials], [new design system][new-system], [adoption guide][adoption].

| Reference | Observed pattern | GistPad decision |
| --- | --- | --- |
| Apple Notes | Content can be browsed as a list or gallery. Apple's Duo example preserves list/detail relationships as the device folds. [Notes][notes], [Duo HIG][duo] | Choose presentation for the collection's job. Keep a native navigation spine and persistent selection, rather than copying a desktop pane arrangement |
| Reminders | Named Smart Lists expose useful views of the same underlying items. [Smart Lists][reminders] | Daily Notes, Starred and Archive are understandable collection routes, not hidden state switches |
| Journal | Dates, filters and bookmarks provide different ways back into personal entries. [Journal][journal] | Give Today a real date identity and make Daily Notes navigable. Do not import streaks, prompts or a journaling dashboard |
| Freeform | The canvas holds the user's material, while explicit tools add and manipulate content. [Freeform][freeform] | Keep the writing surface stable and tools contextual. Do not import an infinite canvas or board-management furniture |
| Mail | Sender/subject/preview hierarchy and meaningful snippets support rapid recognition. [Mail][mail], [Typography][typography] | Titles lead, a real cached excerpt helps recognition, and metadata has one subordinate rhythm |
| Photos | Library and Collections serve different browsing purposes. [Photos][photos] | A featured collection can have a different composition without making every ordinary note a card |
| Files | Search scope and exact file identity are explicit. [Files][files] | Distinguish the note from the file inside it. File switching must never be an ambiguous second "Rename" menu |
| Bear | Native Markdown, tags, readable content and little competing furniture coexist. [Bear][bear] | Keep useful syntax and metadata visible without turning the editor into a formatting dashboard |
| Things | Its Duo adaptation reveals a sidebar when useful and lets the list regain space. Its published two-window example is two app windows, not three panes in one app. [Things on Duo][things] | Expand context, not the number of permanently squeezed columns. Keep creation direct |
| Drafts | Capture starts with the keyboard ready, before organizing or dispatching text. [Drafts][drafts] | Create opens the real local editor immediately. No preliminary naming form or network wait |
| iA Writer | Writing and rendered output are deliberately distinct, with direct navigation and a purposeful keyboard. Apple recognized it as a 2025 Interaction finalist. [iA Writer][writer], [2025 awards][awards25] | Two excellent modes of one document, not a compromised hybrid. Do not copy its typefaces or swipe gestures |
| Craft | Daily Notes, quick entry and extensive native integrations make substantial capability accessible. [Craft's current listing][craft] | Aim for comparable speed and discoverability, not its block model, workspace scope or third-party AI |
| Day One | Its published timeline makes date, title, excerpt and real media do the identifying. [Day One][dayone] | Make personal content the interest. Do not invent an illustration for each note |

The award references reinforce this, rather than supplying a visual style to copy. **Crouton, 2024 Interaction winner**, is praised for information hierarchy and the next useful action. **Lumy and Denim, 2025 finalists**, demonstrate coherent palette and purposeful polish. **Moonlitt, 2026 Interaction winner, and Tide Guide, 2026 Visuals winner**, connect platform behavior, legible information and a coherent visual identity. GistPad needs that completeness, not an accumulation of their effects. [2024][awards24], [2025][awards25], [2026][awards26].

These are primary documentation, developer descriptions and published visual references, not hands-on testing of those apps. Bear and Day One marketing images inform composition, not claims about iOS 27 APIs.

## Primary sources

Research accessed October 24, 2026. Platform facts above come from Apple. GistPad compositions and metrics are design recommendations, not claims that Apple prescribes these exact layouts.

[materials]: https://developer.apple.com/design/human-interface-guidelines/materials
[new-system]: https://developer.apple.com/videos/play/wwdc2025/356/
[adoption]: https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
[duo]: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
[arrangement]: https://developer.apple.com/documentation/swiftui/arrangementview
[toolbars]: https://developer.apple.com/design/human-interface-guidelines/toolbars
[sidebars]: https://developer.apple.com/design/human-interface-guidelines/sidebars
[split]: https://developer.apple.com/design/human-interface-guidelines/split-views
[typography]: https://developer.apple.com/design/human-interface-guidelines/typography
[color]: https://developer.apple.com/design/human-interface-guidelines/color
[buttons]: https://developer.apple.com/design/human-interface-guidelines/buttons
[menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[search]: https://developer.apple.com/design/human-interface-guidelines/search-fields
[loading]: https://developer.apple.com/design/human-interface-guidelines/loading
[progress]: https://developer.apple.com/design/human-interface-guidelines/progress-indicators
[motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[notes]: https://support.apple.com/guide/iphone/change-the-notes-view-iph65637affe/ios
[notes-writing]: https://support.apple.com/guide/iphone/create-and-format-notes-iph1ac0b3a2/27/ios/27
[reminders]: https://support.apple.com/guide/iphone/use-smart-lists-iphe882772ed/ios
[journal]: https://support.apple.com/guide/iphone/view-and-search-journal-entries-iph6257be047/ios
[freeform]: https://support.apple.com/guide/iphone/get-started-with-freeform-iphb86e84e2b/ios
[mail]: https://support.apple.com/guide/iphone/check-your-email-iph461684497/ios
[photos]: https://support.apple.com/guide/iphone/get-started-with-photos-iphc259d0ac7/ios
[files]: https://support.apple.com/guide/iphone/find-and-view-files-and-folders-iphe4bff8827/ios
[bear]: https://bear.app/
[things]: https://culturedcode.com/things/blog/2026/10/hello-duo/
[drafts]: https://getdrafts.com/
[writer]: https://ia.net/writer
[craft]: https://apps.apple.com/us/app/craft-notes-documents-ai/id1487937127
[dayone]: https://dayoneapp.com/
[awards24]: https://developer.apple.com/design/awards/2024/
[awards25]: https://developer.apple.com/design/awards/2025/
[awards26]: https://developer.apple.com/design/awards/
[widgets]: https://developer.apple.com/design/human-interface-guidelines/widgets
[controls]: https://developer.apple.com/design/human-interface-guidelines/controls
[widget-interactivity]: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
[associated-domains]: https://developer.apple.com/documentation/xcode/supporting-associated-domains
