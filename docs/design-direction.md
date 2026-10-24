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

**Library is the navigation home.** It contains Today, Pinned and the recent Notes list. Use "Library," not the app name, as the useful navigation title. A native collection picker at that title exposes All Notes, Daily Notes, Starred and Archive, with the current choice checked. Collection and tag filtering must be reachable without scrolling past the whole notebook. Search and Compose remain direct toolbar actions. Settings lives in the Library menu.

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

**Type is expressive in specific places.** SF supplies all interface text and prose. The Today day numeral uses system Rounded, about 44 pt at standard type. Rendered authored H1/H2 use system New York, not a bundled imitation. Other headings, navigation labels and generated "Contents" controls remain SF. Code uses scaled system monospace. Use Dynamic Type and language fallback throughout, not fixed font names. [Typography][typography].

**Density has a rhythm.** Use 4/8/12/16/24/32-pt relationships, with 20-pt outer content margins as the normal compact starting point. Keep 32 pt between major Library sections and 8 pt between a section heading and its content. Internal spacing is smaller than the gap between sections. Controls have at least 44-pt targets, but a control's target is not an instruction to add another 44-pt container around it.

**Shapes are related, not identical.** Featured content can use a softly rounded continuous container, around 20 pt with 16-20 pt inner space. Ordinary notes share one inset-grouped list surface. Tags retain their existing smaller rounded labels. System controls own their capsule geometry and concentricity. No heavy shadows, imitation bindings or an outline around every row. [New design system][new-system].

### Color: honor the person, keep the page coherent

**Use a valid saved profile `accentColor`. Use GistPad sky `#0EA5E9` when it is absent.** A stored yellow value is still a saved choice. Do not reinterpret it as missing merely because the web's default is yellow. The original blue icon stays unchanged.

This is based on the real contract in `gistpad.dev/src/features/account/queries.tsx`: the web declares `accentColor`, defaults it to `#facc15`, and saves preference changes to Supabase user metadata. Native currently preserves that key in `Packages/GistPadSync/Sources/GistPadSync/Preferences.swift` but does not consume it. A fixed native yellow or blue theme is not profile support.

The accent affects actions, selection, the date accent, caret and app-owned interactive marks. It does not recolor body text, semantic errors, tag colors or the Markdown syntax palette. External prose links retain their underlined semantic link treatment. Sky is the default, not a requirement that every person's notebook stay blue.

Derive one shared native/preview role set from the saved RGB value:

| Role | Rule across Light / Dark / Light Increased / Dark Increased |
| --- | --- |
| `accentText` | Start with the saved color. Find the smallest mix toward black in Light, or white in Dark, that reaches 4.5:1 against the resolved opaque surfaces where it is used. Increased Contrast targets 7:1. Derive each appearance independently |
| `accentFill` + `onAccent` | Prefer the original opaque fill. Choose black or white foreground by greater contrast. If that pair misses the appearance's text target, minimally adjust the fill toward black or white and choose the nearer passing pair. Do not assume white text works |
| `selectedSurface` | Composite a restrained accent tint onto the semantic surface and use normal ink, not accent-colored body text. Check the final ink/background contrast. Selection also has its native trait/check, never color alone |
| System material controls | Supply the appropriate dynamic tint through native APIs and retain the system's material/foreground adaptation. Evaluate the actual material in context, not just a flat swatch |

Use WCAG relative luminance/contrast on final composited colors, not HSB brightness as a proxy. Nontext affordances requiring a visible boundary need 3:1. Test yellow, white, black, saturated colors and missing/invalid values in all four appearances. Preserve the stored hex; readability adaptation must not rewrite the account preference. Invalid data keeps a native fallback and an explicit Settings explanation, not a silent metadata repair. [Color][color], [Adoption][adoption].

This replaces the old fixed-accent proposal. Appearance changes update attributes/colors only, never source bytes, selection, scroll or Undo. Settings offers one opacity-free color control backed by the same profile field, not a new independent native theme system.

## Surface decisions

| Surface | Composition and interaction | Native pattern and reason |
| --- | --- | --- |
| **Library** | Today, Pinned, Notes. Notes use headline titles, an optional real cached excerpt and one subordinate metadata group for tags/time/file count. No placeholder excerpts or network fetches for decoration. Ordinary rows have inset separators and content-driven height | Native navigation, collection picker, searchable list, swipe/context actions. Recognition and comfortable scanning, rather than either a dense web tree or huge isolated cards |
| **Today** | One full-width date-led feature. Rounded day numeral, month, Today/weekday, a genuine excerpt when present, and modest task progress only when known. Use an accent-tinted date area, not an illustrated cover. Leave real space before Pinned. Existing Today opens directly. Start opens Edit with the caret at the end | A featured content button and native progress presentation. Date is the distinguishing content. No automatic creation on appearance, streaks, fabricated tasks or "Earlier days" carryover |
| **Pinned** | A distinct featured group, not the ordinary list with a pin header. Use content cards when at least two readable cards fit: minimum 156-pt card width and 12-pt gaps. Exact title, one useful excerpt and existing labels. No repeated recency line, fake cover, extracted emoji, colored binding or fixed card height. Narrow/AX/sidebar layouts use full-width featured rows | Adaptive collection with ordinary selection and context actions. Pinned is a small set of deliberate destinations, so it earns more visual weight than the scan list |
| **Daily Notes / Starred / Archive** | Dedicated, titled collection views using the same row language. Daily files are navigable newest first. Archive is visually ordinary, not dimmed or treated as deleted. A clear restore action and truthful empty state | Native collection navigation and lists. These are useful retrieval paths, not extra dashboards |
| **Reading** | A composed page with the metrics below, deliberate heading contrast and no healthy-state footer. Render the user's actual headings and emoji. Do not inject the note description as another giant heading | Native scroll container behavior around offline bundled WebKit content. Reading should not look like a web panel, despite the rendering implementation |
| **Editing** | One retained native text view. Clear Markdown structure: purple emphasis/headings in Dark, green quotes, meaningful blue numbers/links, and monochrome code. Preserve the source characters. Edit/Preview keeps the relevant passage and previous selection rather than repeatedly jumping to the beginning | Native text selection, Undo, Find, Writing Tools, composition and keyboard behavior. Color assists structure, not language-rainbow decoration |
| **Split** | Same draft and document session in Source and live Preview. No duplicate pending-photo shelf or second save state. Thin divider; no separate "preview card." Show Edit / Split / Preview directly when eligible | Native mode control and adaptive pane arrangement. Split is a writing tool, not a new navigation root or another copy of the document |
| **Keyboard tools** | One native interactive glass capsule with space around it and 12-pt separation from the keyboard. Six direct targets: Aa, Bold, Italic, Lists, Insert, Hide Keyboard. Dismissal is always visible. On genuinely constrained layouts, fold Bold/Italic into Aa before shrinking targets or hiding dismissal | `UIGlassEffect`, native buttons and anchored menus. Do not depend on toolbar overflow to hide an essential escape. Find remains a note command and Command-F |
| **Tags** | Preserve installed tinted labels, dots, full names and user colors. The picker is one compact searchable list: swatch/name/check, minimum 44-pt total rows, one scope footer. Remove the duplicate "On this note" shelf, "All tags" heading and enclosing group cards. Editing is a swipe/context/named accessibility action | Native sheet/list/search, medium/large detents, initially large at AX sizes. Metadata can be colorful without making the management surface bulky |
| **Search** | Direct native toolbar Search, immediate typing and one normal result list. Show current collection/tag scope and allow broadening. Reuse recognizable title/snippet/labels, not a second card design. Describe exact title/filename/tag scope and cached-content coverage; do not imply a full-text index that does not exist | System searchable presentation, suggestions/scopes where supported. No extra Search tab for this single-notebook app and no custom floating search panel. [Search fields][search] |
| **Settings** | A small native Form: account, writing behavior, saved accent and relevant appearance options. No hero, dashboard or decorative grouped cards inside grouped cards. Destructive account actions isolated. Label the writing toggle Autosave While Writing and explain background saving once in its footer | Familiar settings hierarchy. The current web-parity saving decision belongs to product behavior, not a design-created sync system. Preference copy must describe the actual triggers |
| **Intelligence** | Native Writing Tools is the current capability. V1 also includes exactly three approved whole-note actions: Ask, Edit and Review, using the surface below. No tag suggestions, selection/section modes, inactive placeholder button, assistant rail or separate global chatbot destination | Apple Intelligence as a writing capability, not a competing product inside the notebook |

### The reading page, precisely

The current screenshots fail first on **where the page starts**, then on composition. Content may pass under native controls while scrolling, but the first heading must be below them at rest. Soft scroll edges are a consequence of real underlap, not permission to hide the beginning of the note.

| Element | Starting metric at standard type |
| --- | --- |
| Measure | Full useful compact width minus a single 20-pt gutter on each side, capped at 64ch on wider pages. A narrow split pane may use 16 pt. Never stack native and CSS gutters |
| Page start/end | 24 pt after the unobscured top boundary. At least 40 pt of page breathing room at the end, with native bottom inset additionally keeping the last line above actual controls |
| Body | SF, 17-pt body reference, approximately 1.5-em leading, paragraph gap around 0.85 em. Scale with resolved native metrics |
| H1 | New York bold, native title1 reference around 28/34 pt, 16 pt after. No top margin when first |
| H2 | New York semibold, title2 reference around 22/28 pt, about 28 pt before / 10 pt after |
| H3 and lower | SF with the existing title3/headline hierarchy, about 24 pt before / 8 pt after |
| Lists/tasks | A clear marker gutter, consistent wrapped-line alignment and tighter rhythm within a list than between sections. Task targets remain at least 44 pt without dimming read-only labels |
| Code/tables | Scaled monospace and quiet opaque surfaces. Horizontal overflow stays local to the code/table, never shifts the page |
| Anchors | Land the target about 16 pt below the actual unobscured top, not below an assumed browser origin |

One deliberate native preview adaptation is proposed: an authored/generated table-of-contents module starts as a compact **Contents disclosure**, rather than a large expanded card occupying the opening screen. Its expanded links keep usable targets. Never inject it into a note that did not request it, and do not change the authored open state of ordinary HTML details. The module label uses SF, not the authored-heading serif.

Keep native bounce and responsive scrolling. One soft edge treatment per pane where controls actually overlap. No CSS masks, painted gradients, hard content cutoff above a nonexistent footer, doubled safe areas or scroll reset on each source generation. Preview refresh must preserve the current passage. [Materials][materials], [New design system][new-system].

### Menus: make object scope obvious

**The title cluster is for file navigation, not miscellaneous actions.** On a multi-file note, identify the note and show the exact selected filename as the subtitle. Its native menu lists files directly with the current file checked, then a separate file-management group: **Rename Current File...** and **Add File...**. Daily files retain newest-first date grouping.

**Rename Note... belongs in the note's More menu.** The same visible menu must not offer an ambiguous Rename and Rename File with identical pencils. This fixes information architecture, not just the choice of symbol. For a single-file note, omit an unnecessary title chevron; Files remains available in More for management.

More starts with a compact Pin / Star / Share / Copy Link group. Then note/content commands: Rename Note, Tags, Files, Find and the applicable sidebar command. Open in GitHub is separate. Archive follows, with destructive Delete isolated last. Direct mode controls stay outside More. Use real native sections and purposeful symbols, not disabled headings, ornamental separators or a different icon merely to fill every row. [Menus][menus], [Toolbars][toolbars].

### Intelligence has a place, not a new workbench

**V1 has exactly three app-owned actions: Ask, Edit and Review, all on the entire note.** System Writing Tools remains the selection-based capability. There are no custom selection/section actions or tag suggestions. Following the user's later October 24 decision, skip Private Cloud Compute. This is the surface to implement and review, not a claim that the custom engine already ships.

With these actions, the compact keyboard capsule becomes **Aa / Lists / Insert / Intelligence / Hide Keyboard**. Bold and Italic move into Aa; on a sufficiently wide surface they can reappear as direct targets. Do not bolt a seventh control onto the current compact bar. Intelligence uses a labeled `sparkles` action in the same control language, not a persistent multicolor orb. It is also reachable from the note's menu in Preview.

The surface identifies the note and exact filename before the request, with a quiet **On device** context label, never a model-name or token-budget display. Whole-note scope includes all text of the open file, never a silently truncated passage or unrelated daily files/templates. There is no scope picker. Retain source selection and scroll while open and return to the same passage when dismissed. It grows to a large sheet for review, or a system popover when appropriate, not an always-present third pane.

Use a native three-action picker in this same surface, not an introductory dashboard. Ask is the initial action. Ask/Edit provides a focused prompt field; Review has one clear Generate action. Request, progress, cancellation and result stay in the same sheet. A compact diff stacks labeled Before/After hunks; a wide review can show them side by side. Added/deleted meaning must survive without color.

| Action | Result and commitment |
| --- | --- |
| Ask | A streamed answer about the whole note, with a way back to referenced source passages. Quotes must match the snapshot. No source mutation or global chat destination |
| Edit | Changes across the whole note presented as one reviewable diff. Apply the accepted set as one transaction and one Undo step |
| Review | Whole-note comments anchored to exact source quotes, with optional replacements the user can apply individually. Comments remain separate from source until Apply |

Edit and Review share exact-quote replacement hunks against the captured source; do not require the model to regenerate a long note. Reject nonmatching or overlapping hunks and report the omitted count in the review. Never offer Apply for an unverified anchor. The app computes the diff, not the model.

Everything runs on device. A note that fits the measured request budget takes one pass. Longer notes use bounded passes covering every section, with final synthesis for Ask and merged anchored replacements for Edit/Review. Show honest progress such as **Reviewing part 3 of 7**, then **Preparing changes**. Say "section" only when the units are actual authored sections. Do not claim a partial pass covers the whole note. Cancellation or a failed pass never partially applies source.

If whole-note processing is unavailable, explain why. Do not quietly use an excerpt, introduce smaller-scope modes or expose token budgeting as the user's problem. Unavailability or refusal preserves the request and original note. Never fall back to another provider. Read-only notes support Ask/Review, but source Apply is unavailable with a reason. Real generation remains hardware acceptance.

Proposals never enter the source or publish before Apply. A changed account, document or unrelated source edit invalidates stale Apply and offers regeneration rather than overwriting newer work. Applying one Review comment deterministically updates the remaining verified anchors; it must not require a model rerun for every comment. Applied edits follow the normal saving policy. Availability, loading, cancellation and errors stay inside this surface, with the original note usable when it closes. No new intelligence-generated sync states or permanent dashboard.

## M4: the same notebook outside the app

These are focused entrances to Today and existing notes, not miniature copies of Library. Use native widget margins, text styles and rendering modes. Profile accent belongs in full-color presentation; system tinted, clear and StandBy night appearances retain their own treatment. Personal task/excerpt content is privacy-sensitive. [Widgets][widgets].

| Surface | Treatment |
| --- | --- |
| Small Today widget | Rounded date, Today and one useful task with a real check target. If there are no tasks, show a genuine short excerpt or Start Today, never an invented task |
| Medium Today widget | Date/count at leading, up to two readable task rows alongside. Prefer fewer rows over tiny labels/targets. Tapping the background opens Today; task controls perform the real action in place |
| Lock Screen | Rectangular: date and one legible task/check where space permits. Inline/circular: date or remaining count, opening Today rather than cramming in a checklist |
| StandBy | Adapt the small widget, emphasizing date and one useful task at distance. Let the system remove the background and apply its night treatment. No extra clock or custom glow |
| Add to Today | One `square.and.pencil` control named Add to Today. Open a native quick-capture sheet when text is needed: destination date, focused input, Text/Task choice, Cancel/Add. The shortcut accepts provided text and the same choice without redundant UI. No blank/placeholder insertion |
| Spotlight and links | Real note title, useful cached snippet and exact filename when needed. Open the target through one router, with the same immediate cached selection and truthful loading/error states as Library. Preserve a pending destination through sign-in. Never substitute Today or create a note for a missing target |

At accessibility text sizes, Small uses a compact date and the real remaining-task summary, with the whole widget opening Today. Medium retains one readable interactive task. Do not cap Dynamic Type to preserve a checkbox whose task cannot be identified. Completed task labels use secondary ink alongside the filled check.

Quick capture shows the pinned destination as a localized short date. Text and Task use quiet, non-inserting prompts, native cancel/confirm roles and retained input on failure. At accessibility sizes, the kind picker becomes a labeled native menu, with at least two scaled writing lines kept above the keyboard. Errors use the shared friendly mapping and normal semantic text, not raw red diagnostics.

Interactive checks bind to the displayed date/file and task anchor, never a row index in whichever note is now open. A stale task is not modified and offers Open Today. Locked-device interaction follows system authentication. Missing account/content gets a clear sign-in/open invitation; timeline refresh never creates a note. Widget/control mutations use existing durable-draft behavior, not a separate publication path. [Widget interactivity][widget-interactivity], [Controls][controls].

Universal links need the website's deployed AASA association as well as the app entitlement. A prepared local file is not live link acceptance. Keep the browser fallback truthful until that deployment; `gistpad://` serves app-owned routes. [Associated domains][associated-domains].

## States and movement are part of the design

| Situation | Required experience |
| --- | --- |
| Existing cached note | Selected title and real content immediately. No previous-note frame, placeholder or network-dependent entrance |
| Uncached first open | Selected title immediately, then a few static, accessibility-hidden redacted body lines at the real page margin. No floating progress capsule, shimmer or fake text. Announce loading accessibly. Replace with content using a short crossfade, never a second navigation |
| Create / Today Start | Real locally durable source session, Edit, caret ready and keyboard requested on attachment. Create requires no network. Normal cached Today is immediate. If Today must discover its remote identity or required template, show that genuine pending state rather than inventing content |
| Failed read / offline without cache | Keep the selected identity, state the problem and offer Retry. Do not reveal another note or substitute an empty document that looks editable |
| Empty notebook / first run | Original notebook artwork at a modest size, a short invitation and one clear sign-in/create action. No marketing carousel. Signed-in emptiness must not look signed out |
| Empty collection / no search results | Explain this collection/query and offer the relevant create, clear-filter or broaden-search action. No generic notebook illustration masking the cause |
| Healthy saving | No footer, status pill, reserved empty bar or recurring haptic. Manual Save appears when genuinely needed. Offline pending work gets a quiet explainable icon; actionable failures get one compact notice and recovery action |
| Conflict / local failure / Photos | Preserve their explicit safety and privacy behavior. Compact native problem surfaces, not decoration. Public-image notice must remain legible above the keyboard. A pending shelf is bounded and scrollable without eliminating the writing viewport |

Loading guidance supports useful content and truthful progress, not a rule to animate every cache hit. [Loading][loading].

Use the native transition from a collection into its detail, native menu/sheet presentation and the glass control's touch response. Do not put a custom cover animation ahead of a ready caret. Card zoom is optional only where its matched source remains stable and cancellation is correct. A direct task completion or pin can have one brief symbol/haptic response **after** the local action succeeds. No haptic for background saving, refresh, initial appearance or every keystroke. Reduce Motion uses the settled state without loss of meaning. [Motion][motion].

### Three signature moments

1. **Today turns a page.** The Rounded date changes with one roughly 250-ms numeric transition only when the actual day changes, not on every Library appearance. Opening uses the system transition from its stable feature source. No midnight haptic or decorative cover flip.
2. **A task lands.** After a successful local toggle, replace the circle with its check in one roughly 200-ms symbol transition and one light impact. Keep the note line in place. Widgets use supported content transitions after the intent succeeds; system feedback, not promised custom widget haptics. No confetti or success before persistence.
3. **A new page is already yours.** Compose presents the real source through native navigation, with the caret visible and keyboard requested on attachment. One soft impact acknowledges accepted local creation. No naming interstitial, delayed reveal or haptic on restoration. Input is never held for the animation.

Reduce Motion replaces the first two with their settled state. The keyboard and navigation keep system behavior.

## What we cut, and what earns approval

Cut the fake notebook covers and bindings, extracted emoji faces, solid web tag pills, additional accent systems, persistent save explanations, generalized dashboards, compulsory three-column Duo layout and decorative transition sequence. Keep the original icon, current labels, real content, strong hierarchy and useful power.

The overnight request supersedes waiting for another user review before building. Designer still reviews one connected real-app flow, not isolated styled fixtures: Library to pinned note, long reading scroll, Edit and typing, visible keyboard dismissal, file switch, Create, Today, Tags, search, Settings and the three intelligence actions. Repeat in Light/Dark, Increased Contrast, large/AX text and reduced effects. Include empty, offline and failed states. The user reviews the outcome in the morning. Actual Duo poses remain a hardware acceptance gate.

**Evidence so far is a baseline, not whole-app sign-off.** The user's four screenshots show installed `6449375`. Interface's synthetic `73c84b6` captures confirm that changing tint alone does not fix Library hierarchy and the Tags picker still repeats large sections. The fresh `081d35a` Light/Dark reading frames place the complete resting heading correctly; their expanded Contents block still dominates the page. The same checkpoint shows a legible Photos notice and unobscured native picker at Large. The focused Dark source frame has clear keyboard-tool separation but an unacceptable paragraph/title collision. Scrolling edges, AX Photos, pending-shelf writing space, Search, Settings and open menus remain unaccepted. All these 466-pt frames have unverified posture. Latest fixes must not inherit approval from older screenshots or tests.

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
[menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[search]: https://developer.apple.com/design/human-interface-guidelines/search-fields
[loading]: https://developer.apple.com/design/human-interface-guidelines/loading
[motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[notes]: https://support.apple.com/guide/iphone/change-the-notes-view-iph65637affe/ios
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
