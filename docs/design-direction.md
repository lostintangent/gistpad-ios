# GistPad Native: design direction

Owner: Designer. This document owns the current product and interaction contract. [design-system.md](design-system.md) owns visual tokens, rendering and the review gate. These are specifications, not a release inventory or whole-app sign-off. Git and the channel retain decisions and scoped acceptance evidence.

## Direction

**A lively notebook and an excellent writing instrument.** Optimize three entrances: New or Today, a pinned gist, and filtering to find a gist. Pins lead the list and ordinary notes scan quickly. Identity comes from the original notebook icon, real excerpts and the user's tag colors. Native controls supply navigation, depth and feedback. Reading and writing stay composed around the same passage.

Use one vocabulary: a **gist** is the GitHub object, a **file** is an exact file inside it, and the open **note** is the document being read or edited. Tags, pins, stars, archive state and GitHub comments belong to the gist. A Daily Note is one dated file, not its backing gist.

Cached words, immediate input and continuity matter more than decoration. No invented note covers, extracted emoji faces, stationery, permanent command dashboard or glass prose. Preserve authored titles and emoji exactly. The web is the reference for capability and speed, not appearance.

## One adaptive notebook

Home is titled **GistPad**. The Library puts a Pinned section first, then ordinary gists grouped by last update, then conditional native Daily Notes, Starred Gists and Archived Gists disclosures. It removes the Library title-menu collection switcher, not the document's file menu. New and Today stay direct rail actions; Search remains one tap away in either posture.

**Approval boundary:** the Pinned section, date groups, large title and rail/disclosure layout are user-approved for implementation. Native acceptance is still required before shipment.

| Available space and task | Composition |
| --- | --- |
| Compact window or cover display | Library pushes one document through native navigation |
| Room for navigation and a useful page | Native Library sidebar + document |
| Deliberate Split | Source + live Preview; Library yields before either document pane becomes cramped |
| Genuinely roomy window | Library + Source + Preview only when both document panes remain useful after controls and reserved regions |

Two document panes need at least 320 useful points each at standard type, plus their divider and applicable reserved space. This is a lower bound, not a Duo breakpoint. Large type and the keyboard may require fewer panes. Remember an explicit device-local mode preference without forcing unavailable Split. Keep document controls with the document and Library controls with Library.

Use usable container geometry and native size classes, not device names or orientation guesses. Respect asymmetric safe areas, reserved camera/folding regions and system side bars. Do not force bars to the top/bottom or manually redistribute native items. `ArrangementView` is not a drop-in inside existing navigation/layout containers. Actual pose transitions and reserved-region handling require their own evidence. [Duo guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview).

### Opening and continuity

Without an explicit destination, restore the account's last accessible note/file and durable interrupted edit. Otherwise ensure a durable local Today and open it quietly without the keyboard. Never publish an untouched default day, replace a newer selection, push a deliberately visible compact Library into detail or create another note merely by unfolding.

Existing notes open rendered unless resuming a genuine interrupted edit. Create and explicit Today open Edit, requesting the keyboard when the retained editor attaches. Today places the caret beneath its heading. Create requires no network; necessary remote/template discovery gets an honest pending state.

| Opening state | Experience |
| --- | --- |
| Cached | Selected title and real local content immediately, including offline. No previous-note frame, skeleton, loading flash or wait for refresh |
| Uncached, pending | Known title and semantic page immediately. After 350 ms, one native circular progress indicator with “Opening note...” in scaled subheadline, 12 pt below, centered in the usable detail viewport |
| Ready | Replace progress immediately, with no minimum hold, second entrance or delayed input |
| Failed / offline without cache | Retain selected identity, explain the condition and offer Try Again. Never substitute another note or a blank editable file |
| Empty / first run | Modest original notebook artwork and one relevant sign-in/create invitation. Signed-in emptiness is not signed-out state |
| Empty collection / no matches | Explain the actual scope/query and offer clear-filter, broader search or creation as appropriate |

The progress delay belongs to its request and is canceled on replacement, departure or completion. Back/Library remain available. Do not enable document mutation or request the keyboard before the real session is ready. Expose progress as one “Opening [note title]” element without repeated announcements or focus theft. No fake paragraphs, percentages, timed slogans or shimmer.

**The collection owns membership. The document owns its session.** Scope changes retain an out-of-scope document with no selected Library row, never an injected Open document shelf. Keep visible List selection separate from retained document identity: a system-written nil selection is not departure. Do not select the first result, clear Review or reset caret, scroll or Undo. Returning to a matching scope selects the real row. An explicit different-note/Today choice follows normal departure policy.

One retained source session survives mode, sidebar, inspector and layout changes. Folding alone never publishes, accepts a proposal, changes mode or resets Undo. Reading does not unexpectedly raise the keyboard; active editing retains its intended input state. Preview updates preserve the visible passage, not merely a raw content offset.

## Library and Today

### Library title and list style

Compact and regular Library use the system large navigation title **GistPad** with its gist-count subtitle, which collapses into the bar on scroll. Use no inline title, custom font, manual size or offset. The subtitle counts the unfiltered main collection, including each pin once. At accessibility sizes the title may wrap or truncate before toolbar controls do, and the rail never moves to make room.

Compact uses `.insetGrouped`, the rounded grouped style in the Notes reference. The regular sidebar keeps `.sidebar`, with the same sections in the same order and native sidebar selection. A collapsible `Section` shows its chevron in both styles. [Section](https://developer.apple.com/documentation/swiftui/section).

### Pinned and date groups

The Library list is one native `List`, in this order: **Pinned**, date groups, then the conditional secondary disclosures. Every gist appears once. A pinned gist appears only in Pinned, not in its date group.

- **Pinned** appears only with known positive pins, sorted by last update, newest first, like every other section. It has the same header as every other section: a decorative monochrome `pin` symbol (user, Nov 1), a quiet count and the trailing disclosure control described under Secondary collections. It uses `Section(_:isExpanded:content:)` and starts expanded. Its collapsed choice is account-local and survives navigation, layout changes and relaunch, like the disclosures. Unknown pin membership stays absent.
- **Date groups** place each unpinned gist by its cached last update, using the same calendar-day comparison that produces its row date. Groups appear in this order: **Today**, **Yesterday**, **Previous 7 Days** (2 to 7 days ago), **Previous 30 Days** (8 to 30 days ago), a localized month name for older updates in the current calendar year, then a year for earlier updates. Groups are newest first, and rows are newest first within each group. Date groups collapse and expand like Pinned, with the same quiet count and trailing disclosure. Their choice is remembered for the session by bucket (Today, Yesterday and so on), not across relaunch, because buckets roll forward each day.
- Empty groups never render, including Pinned with zero pins. A gist without a cached update time shows no date and sorts into a trailing section with no header, after every dated group and before the disclosures. It never receives a guessed date or bucket.
- Rows never move while you type. Edits and publishes reposition a row at the next Library refresh or when you return to the Library. Pin and unpin move a row between Pinned and its date group with native list motion, leaving the open document unchanged.
- Rows are the ordinary rows defined below: same title line, tags, task state, selection, swipe and context actions, and the same `library-note-<id>` identifier. No cards, grid, thumbnails, excerpts or pin glyph. Pin state is conveyed by the section. Pin and Unpin stay in swipe, context and named accessibility actions.
- Tag filters and text search keep this structure. Matching pinned rows reveal Pinned temporarily without writing its remembered collapse choice. Matching date groups expand temporarily in the same way, without writing their remembered choice. Empty-state and count rules stay as specified in Controls and Search.
- Native acceptance must show Closed and Open in Light, Dark and AX3, with a collapsed and an expanded Pinned, long authored titles, tags with progress and Comments, and each date group present.

### Controls and Search

Build every control from semantic, declarative SDK and SwiftUI behavior: system roles (`.close`, `.confirm`, `.cancel`), standard placements, native styles and SDK state. Do not write custom logic or custom styling (tints, labels, frames, glass or hand-drawn chrome) to replace what the system provides unless the user asks for it. Use `.axisBehavior` or another placement hint only when the automatic placement is wrong, and name any remaining custom code, with its reason, in the handoff.

Compact Home's upper native group is **New, Today, Settings**, in that order. Open places **Today directly below Compose in the detail rail**, retaining the document's other eligible actions. In the compact bottom toolbar, **Tags** sits beside a system **Search** magnifier, as in Notes. Search is native `.searchable` with `.searchToolbarBehavior(.minimize)`: it shows only the magnifier until tapped, then expands in place to the full content width with the system close X. Do not write a custom field, a bottom `safeAreaBar`, width or geometry math, or fixed rail coordinates. While the field is open, Tags hides so the query gets the full width; the GitHub attention action is never hidden by search. The regular sidebar keeps native `.searchable`, overflow and one supported trailing sidebar toggle, with no blank leading placeholder.

Preserve full-size Dynamic Type, native placeholder tail truncation, typed-text scrolling, the in-field Clear button and internal trailing clearance. Never shrink the placeholder or let it cross the glass. Compact Search floats above the keyboard without a separate Cancel button. Open retains the system-owned dismissal X supplied by native `.searchable`; this is the accepted exception, not an app-owned Cancel. Hide it only through supported native API, not private view-tree surgery. Clear empties the query without dismissing the focused field. Keyboard Search or scrolling results dismisses the keyboard while retaining the query and results. Losing focus with an empty query ends text search without clearing independently selected tags. Native insertion/selection stays blue. Routine checks never replace the search input. [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields).

Do not show search-coverage prose about titles, filenames, cached note text, incomplete file lists or older content. While any tag is selected, a filter strip sits above Pinned. It shows the selected tags as chips with their check. At the trailing edge sits the count of matching gists in secondary color (`3 gists`, localized plural, from the same predicate as the rows), then the icon-only clear control (`xmark.circle.fill`, labeled Clear Tag Filter) in secondary color. It has no title, such as "All Notes", and no summary line. With no tag selected, omit the strip entirely, including its reserved spacing. This removes presentation noise, not the existing local search boundaries or failure reporting.

Filtering projects the existing local all-collection search into the main list and secondary groups, without a new index, sync path or network fetch for presentation. Temporarily reveal matching secondary groups without writing remembered collapse choices; clearing filters restores those choices. Results use the same Pinned and date-group structure as the main list, with ordinary rows. Do not report global emptiness when another group has matches, hide a matching group behind its collapsed state or claim uncached body text was searched.

### Secondary collections

Use native disclosure-backed sections rather than the title switcher. A switcher hides the rest of the notebook and replaces its list. Disclosures retain one spatial context, make their contents inspectable and leave the primary entrances direct. Use supported `DisclosureGroup` behavior, not a custom accordion. Unlike the web's desktop panels, expanded rows share the one outer native scroll; no capped five-row inner scrollers. [DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup).

After the Pinned and date groups, show **Daily Notes**, **Starred Gists**, then **Archived Gists**, only with known positive unfiltered membership. Empty sections never render, including a collapsed header with `0`. Each starts collapsed and remembers its explicit account-local choice across navigation, layout changes and relaunch. An active note remains usable when its section collapses or disappears. Today/deep-link opening does not rewrite disclosure preferences or force the Library to scroll away from pins.

Headers are single native disclosure targets with the system's prominent header style (`.headerProminence(.increased)`, approved by the user Nov 1). Each shows its full readable title, a quiet localized count such as `2` in secondary color, and at the trailing edge the Notes Pinned disc, `chevron.down.circle.fill` in `Color(uiColor: .secondaryLabel)`, which matches Notes' Pinned disc pixel for pixel in Dark (Lead's measurement, Nov 1). Do not use `.tertiary`, which is darker. The whole header row is one plain system `Button` that toggles its section, so the disc is its visual and tapping anywhere on the header works. Collapse swaps the symbol to `chevron.forward.circle.fill` with the replace content transition, not a custom rotation. The disc takes the header's own text style, so it measures about one cap height with the chevron inside it. Do not draw the disc or fix its size. `Section(_:isExpanded:)` owns collapse, animation and disclosure state. Where the list style already draws its own disclosure (Open's sidebar), that one stands in and the two never show together; the handoff must name any added control. Only Pinned, Daily Notes, Starred Gists and Archived Gists get a leading monochrome secondary symbol, `pin`, `calendar`, `star` and `archivebox` (user, Nov 1, because these sections are unique). That symbol is decorative and hidden from VoiceOver. Date groups stay plain text. The title supplies the unit; do not repeat "notes" or "gists" beside the count. No colored star, count badge or ornamental rule. Keep the short number on the title row at AX, aligned with its first baseline; let the full title wrap and decorative symbols yield before shrinking type. VoiceOver reads the title and count once, such as "Daily Notes, 2", plus the native disclosure state. Expanded contents retain the ordinary row language, selection and existing actions; no nested cards.

Keep the disclosures in one shared native section. Section headers use the system header font and size with `.headerProminence(.increased)`, and no custom font, color, size, rule or transition. Headers keep the system header inset (user, Nov 1). Closed uses `.listStyle(.insetGrouped)` for compact width. Open keeps the sidebar list style in regular width. Headers take the system section-header rhythm at every size, with no custom pitch, gap, rule or transition. Each collapsed header stays a native disclosure target of at least 44 pt. At AX, rows grow for full-size wrapped content and native target insets, not extra inter-section spacing. Expanded child rows share the outer scroll, with no added section gap before the next disclosure.

### Rows, membership and counts

Use native compact ordinary rows, inset separators, swipe/context actions and one accessible opening action. Regular sidebar selection is a neutral native full-column fill with selected traits and unchanged tag colors. Keep `.sidebar` behavior and native soft scroll edges rather than compensating for system spacing with negative offsets.

| Row content | Contract |
| --- | --- |
| Shape | Two lines at most (user, Nov 1). The title line always, plus a tag line only when the note has tags. No content preview or excerpt anywhere in the list, including search results |
| Title line | Scaled headline semibold title, one line at standard sizes, with the star after it. The trailing edge holds scaled footnote metadata: the comment count and then the date for ordinary rows, or the task state for daily rows. At accessibility sizes a title too long to share its line wraps and the metadata moves beneath it, trailing |
| Date | System `.secondary` label role, the user-requested muted exception, like Notes: exempt from the 4.5:1 and 7:1 normal-text targets and visibly gaining contrast under Increased Contrast in Light and Dark. Localized time today, Yesterday, weekday in the current calendar week, then short date with year when needed. Use the row's actual update, not a guessed timestamp or ticking seconds. No custom opacity |
| Tags | Optional second line, 6 pt below. Complete dot-free labels and honest overflow, with the comment count trailing on this line when the note has tags. No mandatory tag space or nested tiny buttons |
| Daily | Always one line: the localized date title, then trailing task state. No tags, comment count, repeated date, filename, gist file count or relative modification line. Keep filenames/source and overdue-first ordering |
| Other state | Small neutral star outside Starred when useful. Public/secret and ownership remain accessible and available in Details. Do not imply secret gists are private or add a lock to every row |
| Actions | Whole row opens. Preserve native swipe, context and named accessibility actions, confirmation safety and availability. Details/files stay reachable without extra row furniture |

Sidebar rows keep the system horizontal inset, with no custom content inset and no missing-icon gutter. Compact rows use a 16-pt horizontal content inset from the card edge, a little narrower than the native inset yet not cramped. Ordinary rows use about 14-pt top/bottom padding, with the List's vertical row inset at zero, so a one-line row lands near 50 pt and a tagged row near 80 pt. Confirm the final padding against a Closed Dark capture, per the Dark-only scope for this pass. Keep 6 pt before tags. Scale vertical tokens with Body metrics, without a cap. No empty header space remains above headerless groups. Separators start at the text edge; selected fills replace adjacent boundaries, never draw through their fill.

The comment count, when known and positive, sits trailing on the tag line when the note has tags, and otherwise just before the date on the title line. It never truncates. Choose the accessibility layout with a native Dynamic Type switch, not width math. Daily Notes show no comment count (see GitHub Comments).

Daily-row task state is one trailing neutral ring plus tabular `3/4` in scaled footnote. Neutral numeric counts and the filled arc use full-opacity semantic label ink; only the track is quieter. Measure text against the actual selected/unselected surface, not just the page. Completion replaces the ring with fixed semantic-green `checkmark.circle.fill`, keeping `4/4`. Only overdue unfinished counts use contrast-safe amber. Unknown/no tasks omit the cluster; known zero complete shows `0/4`. No separate progress row or nested task toggle. VoiceOver receives completed/total/remaining and overdue meaning in the coherent row description.

Section membership comes from the ordinary account-scoped owned/starred cache, not visiting each scope. Daily rows use actual dated filenames plus durable local drafts, excluding the template. Unknown initial membership is absent; cached positive membership survives refresh/offline. Missing cache, truncated data, failed reads and filters never prove emptiness. Known nonempty rows with an unknown total keep the section visible without a number. First successful membership reveals the section. Remove a section when its last confirmed member leaves, without retaining an empty header or disturbing the open document. Preserve the existing Undo behavior independently of section visibility. Account changes never inherit another account's membership or disclosure choice.

Counts use the same known snapshot and predicates as their rows. Home/Starred/Archive count distinct published gists, excluding recovery/local-only rows and confirmed deletions. Daily counts actual days/notes, not backing gists. Home's subtitle retains localized full “1 gist” / “12 gists” and counts the unfiltered main collection, including pins once, not the sum of overlapping secondary memberships. Secondary disclosure headers carry their own bare localized totals because their titles identify the unit. Under filtering, their bare numbers count matches from the completed current query; omit match numbers during searching/failure and omit groups with no matches. Other Results summaries retain their applicable units. Never use capped count badges or add a heading just for a count.

Keep known counts through refresh/offline and omit unknown counts. Home may show zero for known emptiness; empty secondary sections are absent rather than showing zero. No decorative fetch, independent incremented counter, inferred gist identity or stale-response resurrection. Counts and confirmed membership changes move together. A gist in both the main list and Starred is the same document, never another draft or an extra Home total. At AX, wrap rather than shrink, and speak a heading/count once.

### Today button and excerpts

Use the native outlined `calendar` glyph, primary monochrome ink and a target of at least 44 pt. It is one adaptive toolbar item, with an attached foreground-filled/inverse-numeral badge like Comments, not a custom floating control or extra independent badge target. No personal tint, red urgency, progress donut or completion check.

The badge counts **unfinished tasks in today's exact file**, not all tasks, all Daily Notes or overdue days. Reuse the existing Today task summary from durable local/cached source. Missing source means unknown, not zero. Update after committed local changes and resolve the current account/date; never carry yesterday's count or create/fetch a note merely to decorate the button.

| State | Badge and behavior |
| --- | --- |
| Known 0 unfinished tasks | No badge; calendar remains enabled. Accessibility can state no unfinished tasks |
| Known positive | Exact localized count through 99, then visual 99+; full accessible count. The board shows 3, 12 and 128 |
| Unknown | No badge and no false zero/success claim. Existing opening/recovery remains available |
| Today absent | Same enabled calendar, no badge. Tap stages the real durable local day and opens Edit, never automatically publishes an untouched default |
| Today's exact file is visible | Native neutral selected material and selected trait. A different day in the same gist does not select Today |

Closed taps push Today through native navigation; Open taps replace the document while keeping Library position. Both use the existing explicit Today action, Edit-ready caret beneath its heading and keyboard request on editor attachment. Reuse the retained session rather than creating another copy. Default launch restoration stays quiet as specified above. Day rollover changes the button's target/count, never the open document.

No streak, greeting, carryover, Earlier days, automatic journal text or large-gist Git fallback. Preserve the user's template and its existing file-management entry. Truncated source blocks unsafe writes. Widgets, Open Today, Add to Today and exact daily-note routes retain their existing behavior; only Library presentation changes.

One cached-source extractor serves the Today summary. Skip complete leading frontmatter, following blank lines, the title/date-template header and nonprose code/diagrams. Preserve prose/task words, emoji, link labels and visible inline HTML text while removing Markdown delimiters, destinations and tags. Do not treat mid-document `---` as metadata or present an unclosed metadata prefix as clean prose. Update from the local draft, never fetch decoration, invent a summary or reserve an empty excerpt.

## Note commands and tags

The title cluster navigates files. For multi-file gists, list exact filenames directly, current file checked, then separate **Rename Current File...** and **Add File...**. Group dated series newest-first by UTC Gregorian year/month. Initial file selection follows the web resolver; explicit choice always opens that exact mounted file. Source, Preview and title share the same account/draft/file before editing is enabled.

Show the current exact filename in the native subtitle, except case-insensitive `README.md`. Other filenames get a 4-pt Body-scaled title/subtitle gap. A single-file note needs no unnecessary title chevron; Files remains in More.

More begins with compact Pin / Star / Share / Copy Link, then Rename Note, Tags, Files, Find and applicable sidebar commands. Open in GitHub is separate, Archive is nondestructive, and Delete is isolated last. Use native menu sections, not disabled headings or custom separators. Direct Edit/Split/Preview controls stay outside More. Preserve exact accessible names, selection and toggle state.

Delete uses one confirmation for every note row state, and its wording is true for all of them. Title **Delete “[title]”?** Message **This removes the note from this iPhone and from GitHub if it was saved there, including unsynced changes. This can’t be undone.** Buttons **Cancel** and destructive **Delete**. Phone-only drafts get no separate copy. A daily note’s delete removes only that day’s file, so the same copy applies, naming the note by its title (user, Nov 1). If that file is the last one in its backing gist, the delete removes the gist with no extra prompt. A daily note written offline that never published can go with it. That gap is accepted (user, Nov 1). Only an uncertain creation adds one line: **GitHub may already have received this note. Check your GitHub Gists page and delete any copy there.**

Tags keep web-compatible names and saved colors, and apply to every file in a gist. Metadata labels fill with the exact saved color at full opacity, with black or white text, whichever has higher contrast. That keeps every fill at 4.58:1 or better and passes the 4.5:1 target. A missing color uses a neutral system fill with primary text. No internal dot, tinted overlay or whole-label opacity. Picker rows are untinted with one standalone swatch, neutral name and selected check. No duplicate chip shelf, All tags heading or enclosing group cards.

Use one native searchable Tags editor with medium/large detents, large initially at AX. It has no footer or scope note, because it opens from the note itself and tags are gist-wide by context. Its toolbar uses the system close X (`Close`) and blue checkmark (`Save`), not text labels like Done or Save Tags, and both move into the folded rail when expanded. Its rows are at least 44 pt and grow for wrapping. Edit Tag lives in swipe/context/named accessibility actions, not a second pencil in every row. The filter sheet has no footer, uses the same close X, and keeps **Clear tag filters**. Each tag row shows its matching gist count in secondary at the trailing edge, from the same predicate as filtering (user, Nov 1). The checkmark follows the count, and its space is always reserved so selecting a tag does not shift the number. VoiceOver reads the tag, count and selection state. Both tag sheets use the inline title, so the filter and editor read as one family and the first row stays above the fold at medium detent.

Profile-write capability, not source-write capability, governs tag editing. A signed-in user can tag another person's gist; incomplete source does not itself block profile-only changes. Use a nonmutating version only without a safe account-scoped association or profile-write capability. A failed tag save keeps the chosen tags on screen with a clear message and never silently reverts. Tag edits need a connection. No tags inserted into Markdown.

Settings is a small native Form for account, writing behavior, saved accent and relevant appearance options. **Autosave While Writing** is the first toggle in the Writing section, with no explanatory footer. Destructive account actions stay isolated. Account switching preserves the original account's drafts or offers source export after persistence; it does not discard or publish them.

## Saving and recovery

Local durability and GitHub publication are different states. Every keystroke is saved on the phone first. With autosave on, publish five quiet seconds after typing stops. Always publish when leaving a note for the list or another file and when leaving the app, whatever the autosave setting. Returning to the app refreshes the open note and publishes the notes you've left with unpublished edits. No additional sync machinery. A note with no unsent edits, meaning its text equals the last version fetched from GitHub, silently shows GitHub's latest version on open, on return from background and before publishing. That is never a conflict.

Healthy editing has no footer, reserved strip, success pill, recurring haptic or narrated save pipeline. Show manual Save only when autosave is off. Unpublished edits get one `icloud.slash` status icon labeled **Not published yet**, not a permanent warning when nothing is pending.

Offline, cached notes stay editable, and new notes and files can be created on the phone. Their edits publish at the next trigger after reconnecting. Title, tags, star, archive, rename and delete need a connection and fail with a clear message.

Routine Library checks are quiet; pull-to-refresh uses its own native indicator. The note retains its native trailing status slot: after 350 ms, one small circular native spinner with the actual operation as its accessible label, no forced hold. Cancel the delay when superseded. Transient failures/cancellation do not become warnings; the sync owner determines persistent problems.

Status has three meanings: nothing shown when the note is on GitHub, **Not published yet** when edits are on the phone, and **Needs you** for a conflict or a lapsed GitHub sign-in. **Needs you** shows one neutral native glass `exclamationmark` action labeled **GitHub needs attention**, which opens **GitHub status** in a native popover or adaptive sheet. For a lapsed sign-in, the popover heading is **Couldn't reconnect GitHub.**, and its only action is **Reconnect GitHub**, which starts sign-in directly. If the Supabase session is missing, the body is **Tags and pinned gists can't sync until you reconnect GitHub.** If only the GitHub token is missing, it is **Gists can't update until you reconnect GitHub.** With unsent edits, the body adds **Changes haven't synced. Reconnect GitHub to send them.** for tags and pins, or **Changes haven't reached GitHub. Reconnect GitHub to send them.** for gist content. Edits stay on the phone while the lapse lasts and publish after reconnecting. A failed publish that isn't a lapse stays **Not published yet** and retries at the next trigger, so there is no Retry button. While this control is visible, Library does not also show its own reconnect action.

Say **Couldn't check for updates** for inspection and **Changes haven't reached GitHub** for publication. Claim **Your changes are saved on this iPhone** only after durable saving; inspection-only trouble can say the local notes are unchanged. No raw errors or speculative safety claims.

If the writing keyboard covers the nonblocking remote-status slot, remove it from hit testing/accessibility and restore its unresolved state after dismissal. Do not move it into the keyboard accessory or float it over writing. Local persistence failure, uncertain publication and conflict protections remain explicit above the keyboard.

| Data risk | Required response |
| --- | --- |
| Local write failed | **Changes aren't saved. Keep this note open.** Retry, no safe-offline claim |
| Publication/creation uncertain | Check Status / Check GitHub before retrying. Never blindly duplicate a gist or write |
| Changed remotely while this note has unsent edits | **Needs you**. Keep the local text. Nothing publishes until you choose in Review changes |
| Truncated, unavailable or blocked source | Explain the actual reason and recovery. Never offer unsafe replacement |
| First read failed without cache | Selected-identity page recovery, not a tiny status icon over emptiness |

### Conflict review

**Review changes** opens one native large sheet with the exact filename. Show **Your draft is saved on this iPhone.** only after the draft is durably saved. Dismissing keeps the conflict and the editor position. Nothing publishes while the conflict is open.

Use Changes / My Draft / GitHub. Changes shows deterministic source differences from the base, labeled On this iPhone and On GitHub, with `+`/`-`, exact whitespace and local horizontal scrolling. The other tabs show full read-only source. No permanent three/four-column comparison or second canonical editor.

| Choice | Effect |
| --- | --- |
| **Keep Mine** | Publishes your text over GitHub's. GitHub's version stays in the gist history. |
| **Use GitHub's** | Replaces your text with GitHub's version as one edit you can undo. Copy: "Replace your text with GitHub's version. You can undo this." |

There is no automatic merge and no combined version. Each choice applies only to the versions on screen. Never adopt or merge from a GitHub response that couldn't be fully read.

The session owns selection and Undo. **Use GitHub's** waits for IME or Writing Tools to finish, with visible guidance.

A conflict keeps the note from publishing until you choose, so GitHub's version can't be overwritten by accident. No Apply & Publish. Account changes and quitting keep the draft on the phone.

### Photos

Insert > Photo uses one system PhotosPicker. Capture originating account, draft, accepted generation and UTF-16 insertion location before presentation. Insert after selected text, never replace it. Read-only/incomplete source and active IME/Writing Tools block mutation.

Before this account's first pick, show a dismissible native notice with Continue/Cancel:

> Photos you choose are uploaded to GistPad's public image storage. Anyone with an image link can view them, even in a secret gist. Location metadata is removed, but visible details remain.

Continue opens the picker, not upload. Remember acknowledgment locally per account and retain disclosure help at entry. Cancellation or failed loading uploads nothing. Large type scrolls naturally.

Pending photos use a bounded, scrollable note-local attachment row above problems/keyboard, without consuming the writing viewport. Show thumbnail, Photo, truthful state and recovery. Never insert provisional Markdown, invented URLs, hidden markers or replacement characters; canonical source/copy/share/Preview remain unchanged.

| Actual state | Presentation/action |
| --- | --- |
| Loading/converting | Preparing photo...; no saved claim before queue persistence |
| Invalid/oversize/failed preparation | Explain the failure and Choose Another Photo |
| Durably queued | Photo saved on this iPhone |
| Waiting for gist | Save this note to GitHub to upload the photo. Never create/publish solely to release the queue |
| Offline | Saved on this iPhone. Waiting for connection. No active spinner |
| Uploading / uncertain | Uploading photo... / Checking upload...; reconcile the stable asset ID, never offer duplicate upload or invented percentages |
| Reconnect / upload failure | Reconnect GitHub / Retry, retaining local data and respecting retry timing |
| Uploaded, original target valid | One durable native undoable insertion, then reveal the real Markdown |
| Uploaded, target stale | Photo ready / Insert Here only in the originating note at a fresh safe cursor. Finish composition first |
| Local queue/insertion failed | Couldn't save this photo on this iPhone / Retry, retaining data without a durability claim |

Resume eligible work only for the same account. Never insert into whichever note is now open or guess a shifted offset. Remove the row only after durable source insertion. Undo removes that edit, not the public object, and never reinserts automatically.

Remove Pending Photo requires confirmation explaining that it removes the pending item, not an uploaded image. Do not promise unsupported cancellation/deletion; disable removal during a noncancelable upload. Keep logical VoiceOver order without background focus theft or repeated progress announcements. Live upload tests require explicit user approval.

## Apple Intelligence

V1 has system Writing Tools and exactly three app-owned actions on the **entire open file**: Ask, Edit and Review. Use `SystemLanguageModel.default` on device, with runtime-measured context capacity. No Private Cloud Compute, third-party provider, tag suggestions, app-owned selection/section modes or global chatbot.

The compact keyboard capsule is Aa / Lists / Insert / Intelligence / Hide Keyboard. Bold/Italic move into Aa and can reappear when there is room. Intelligence is also reachable from the note menu in Preview. The native request surface uses the note title as its identity, followed directly by the Ask/Edit/Review picker with 20-pt content insets. No filename/device row, model names/token budgets or scope picker. Availability explanations follow the picker. Preserve document selection/scroll.

Ask/Edit use their focused native sheet/popover. Ask is initial. **Pending presentation integration:** Review's approved document-owned inspector lifecycle below is not a claim that the parked integration ships. Do not add an idle Review tab to ordinary Comments.

| Action | Result |
| --- | --- |
| Ask | Validated whole-note answer and verified source references. No source mutation |
| Edit | Reviewable exact-quote replacement diff; accepted set applies as one transaction/Undo step |
| Review | Private exact-source suggestions, optionally with replacements, applied individually |

Generation immediately shows native circular progress, a readable real phase and neutral Cancel in the usable viewport. Preserve the submitted request through bounded quality retries. No empty answer bubble, simulated typing, shimmer, invented percentage or rejected text flash. At AX, phase/Cancel precede a fully wrapping request echo; no shrinkage or clipped two-line question. Final failure/refusal preserves the request and source.

Ask uses a semibold Body lead and zero to five useful Body points, not padded generic observations or Markdown/chat cards. App-owned neutral bullets have 8-pt hanging-indent gaps. Use 12 pt from lead to points/between points, 20-pt sheet gutters and references 16 pt afterward. Text is selectable, wraps without AX caps and mirrors for RTL. Each point is one logical element. Ready answers precede the full AX request echo without forced scrolling or typewriter effects. Rendering approval is not answer-quality approval.

Only validated prose/citations may appear. Quotes must match the captured snapshot. A long note uses bounded passes covering every section, with honest numbered progress, final Ask synthesis or merged anchored replacements. Never silently truncate, substitute an excerpt, partially apply on cancellation/failure or claim partial coverage is whole-note work. Explain unavailable processing without a provider fallback or new smaller-scope mode.

Edit/Review use app-computed diffs and verified exact-quote hunks. Reject nonmatching/overlapping replacements, report omitted counts and never expose unsafe Apply. No source/publication before Apply. Changed account/document or unrelated edits invalidate stale Apply and offer regeneration. Rebase remaining Review anchors deterministically after individual application, without another model call. Read-only notes allow Ask/Review but explain unavailable source Apply. Applied source follows normal saving policy.

### Private Review presentation

The approved inspector observes one document-owned Review, separate from Ask/Edit's sheet lifecycle. Explicit Review Note starts generation and selects Review, or reveals existing work without rerunning. Only Review Note / Review Again generate; opening Comments, switching tabs, resizing or reopening never does.

Normal Close hides running/unresolved Review without clearing it. Dismiss Suggestion changes no source. More contains neutral Review Again and Dismiss Review; the latter cancels/clears Review, not GitHub comments or composer drafts. Resolving/dismissing the last suggestion removes the picker and returns to Comments, preserving position and sensible accessibility focus.

No suggestions shows its result and Done before clearing. Failure retains explanation and Retry/Dismiss. Closing acknowledges/clears these terminal messages. Cancel Review clears immediately. Document departure/account change clears private Review. Stale Review retains its explanation with Review Again / Dismiss Review and no unsafe Apply.

Use the note title as context, with verified Before/After and individual Apply. No redundant filename/device row, author avatar, Reply, Send, GitHub count or automatic publication. Daily/unpublished notes use the same Review-only inspector without Comments or a picker; final resolution, dismissal, cancellation or Done closes it. Gist-comment eligibility never gates on-device Review.

## GitHub Comments

Comments are a gist conversation attached to the passage, not a new destination. Omit entry/count for Daily Notes and unpublished notes. Default inspector title is **Comments**, with **All files in this gist**, no idle Review picker. Count all gist comments, including replies, not just loaded threads/current-file matches.

| Surface | Native treatment |
| --- | --- |
| Note entry | Direct neutral outlined `text.bubble` toggle. Positive known count attaches to the glyph in one native toolbar item: foreground fill, inverse numeral and separating inverse ring. No red unread styling, separate target or unknown/zero badge. Accessible count remains full even if numeral caps at 99+ |
| Library row | Small neutral bubble/count metadata only for positive known totals. Named Open Comments action opens note/inspector. No decorative fetch or tiny independent button |
| Compact | Medium/large native inspector sheet, grabber and neutral Close, on the same default sheet background as the Tags filter sheet, never the note's page or editor color, so the thread list contrasts the note beneath it. Quoted-thread reveal can use medium/background interaction; composition, reply, AX and keyboard use large. Never stack sheets |
| Regular | Native trailing inspector, ideal 320 pt, adapting to a useful document column. Library yields first. No Library + Edit + Preview + Comments squeeze. Restore prior sidebar/mode preference when useful space returns |
| Threads | Newest first; real cached GitHub avatars with initials fallback, semibold author, named relative date and readable Markdown. No chat bubbles/nested cards or redundant avatar accessibility stop |
| Selected root | Neutral 12-pt rounded surface inset 8 pt, unchanged 20-pt content gutter, 3-by-20-pt personal-accent marker beside author and selected trait. Replies share the surface |
| Replies | Native disclosures through two levels, 12-pt nesting; remove extra AX indentation while retaining spoken parent. No Reply below the deepest supported level. Missing parents never hide descendants |
| Actions | Neutral native bordered Reply and Show Full Quote / Show Less, subheadline semibold, wrapping labels and 44-pt targets. Use return arrow and down/up chevrons. Author can edit; author/gist owner can delete with target-specific confirmation. Preserve stored quote/reply prefix and descendants |
| Composer | One growing native glass text field and a sibling glass send button, in one `GlassEffectContainer` in `safeAreaBar` (the Messages pattern), with no glass inside glass. Conversation bottom `.soft` scroll edge, no app gradient/scrim. The send control is `Button(role: .confirm, action: post)` with `Label("Post", systemImage: "checkmark")` in `.labelStyle(.iconOnly)` and `.glassProminent` in the accent tint. Its spoken name is Post, and its fill is never gray. No custom arrow, image, frame, font or tint, and the composer's tint never reaches it. Keep the Command-Return shortcut. Disabled for empty trimmed text, pending or unavailable posting. While posting, the button stays disabled with its checkmark and no custom spinner |

Thread body is Body, author/quote Subheadline, date Caption, all scaled. Start with 16 pt between comments, 8 pt within and 12 pt around quote context. Opened bodies are uncapped. Reuse Markdown presentation without recursively adding comment highlights.

Composer context is removable Replying to @name or the captured quote; otherwise On GitHub. Revealing a thread never requests the keyboard. Closing preserves a durable account/gist/target draft. Posting is explicit, independent of note autosave, and never automatically queued offline.

### Quotes and native selection

Preserve web wire compatibility: `> quoted text` and `> [comment:<id>]`. The parser hides only the first quote-prefixed line. Preview captures rendered `Selection.toString()`; Edit captures raw selected source. No whitespace normalization, substituted Markdown or source-position mapping.

Matching is exact, case-sensitive, unique, whole-word, minimum three characters, with the existing literal UTF-16/JavaScript `\b` contract. Edit checks source segments; Preview checks eligible individual text nodes excluding pre/code/svg. Formatting/multiblock selections may not highlight in either view. Missing/ambiguous quotes retain usable threads and **Not linked in this view**, never a guessed occurrence/file.

Idle annotations use rounded saved-accent fragments, initially 50% over the opaque page, adjusted for readable existing ink. Selected threads use strong fill, contrast-derived ink and selected traits. **No comment-added underline in Edit or Preview.** Ordinary link and intelligence-diff underlines remain. Native blue text selection/handles take precedence. `showInlineComments=false` hides idle, not a deliberately selected verified quote; historical revisions have no quote annotations.

Add Comment appends to the native edit menu at four trimmed UTF-16 code units. Preserve Copy, Writing Tools, handles, composition, Undo and menu ordering; no floating delayed web button. Use the supported text-range delegate. Preview and keyboard-down Edit taps reveal uniquely matched threads; typing taps place the caret, with View Comment in the native menu. Overlaps use a chooser. Long press and selection remain native. [Text menu API](https://developer.apple.com/documentation/uikit/uitextviewdelegate/textview(_:editmenufortextinranges:suggestedactions:)).

Capture account/gist/file/selection before composition; a later selection never retargets a draft. Post stores captured context plus authored body. Close returns to the same document, caret, selection, scroll and intended input state. Do not gate composition on source mapping.

| Conversation state | Required experience |
| --- | --- |
| Loading/refresh | Initial load shows one native indicator in the thread area, with the composer ready. Refresh is native pull-to-refresh on the conversation (`.refreshable`), with no toolbar refresh button. If VoiceOver cannot reach pull-to-refresh, expose it as a named accessibility action, never a visible button. Retain threads and the known count during refresh. Unknown is not empty and never blocks the note |
| Empty | Shown only after the load returns zero comments: the blank conversation with the normal composer ready. No "No comments yet" message, title, illustration or flash while the count is unknown. An empty gist and a loaded-empty gist look the same. There is no comments cache for t166; first open shows the indicator, then the result |
| Offline | Cached threads and editable local draft. Without cache, explain connection need. No automatic send |
| Post/load failure | Explain the actual operation and preserve draft. Reconcile uncertain Post before retrying to avoid duplicates. Claim saving only after durable receipt |
| Missing thread/permission | Preserve draft and explain target loss. Never silently turn a reply into a root. Source-write and comment permission are separate |
| History | Identify current-gist comments; return to current file before quoted composition. Never point historical quotes into current text |

Native inspector adaptation is the supported starting point, not proof of every Duo pose. [Inspector](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:)), [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

## Entrances outside the app

Widgets, controls, Spotlight and links lead into the same notebook, not miniature Libraries or separate persistence/publication paths. Use native widget margins, text styles, privacy handling and rendering modes. Personal content/accent belongs to full color; system tint/clear/StandBy night treatment remains system-owned.

| Surface | Contract |
| --- | --- |
| Small Today | Rounded date with Today beside it; one genuine task/excerpt/invitation 12 pt below. AX uses compact date/remaining summary and whole-widget opening |
| Medium Today | Date/count and up to two readable interactive tasks. At AX, retain one identifiable task rather than tiny rows |
| Lock Screen / StandBy | Date and one useful task/count where legible. No packed checklist, extra clock or custom glow |
| Add to Today | Native quick capture with pinned destination date, focused input, Text/Task, Cancel/Add. Shortcut-provided text avoids redundant UI. No blank insertion |
| Spotlight / links | Real title/snippet/exact filename as needed. One router preserves target through sign-in and uses ordinary cached/opening/error behavior. Missing targets never substitute/create Today |

Capture commits durably before revealing the inserted line; interruption retains text. Task mutations bind displayed date/file and exact anchor, never the current row index. Stale tasks offer Open Today instead of modifying another note. Locked interaction follows system authentication, missing content/account gets an honest opening/sign-in action, and timeline refresh never creates notes.

Universal links require deployed website AASA plus app entitlement. A local prepared file is not live association. Keep browser fallback truthful; `gistpad://` serves app-owned routes. [Widgets](https://developer.apple.com/design/human-interface-guidelines/widgets), [Widget interaction](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities), [Associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains).

## Motion and approval

Native navigation owns gestures, interactive cancellation and presentation. Never delay a ready caret or words for animation. Widget dates can use a roughly 250-ms numeric transition only when the actual day changes. The Today rail badge updates quietly, with no celebration. Direct task completion gets one roughly 200-ms check transition/light response after local commit, with the line stable. Creation may acknowledge accepted local creation once. Pin relocation uses native list motion, preserving the document.

No refresh/restore entrance replay, midnight/autosave haptic, per-keystroke feedback, confetti, page flip or simulated folding. Reduce Motion shows settled state without lost meaning. Widgets use supported system feedback, not promised custom haptics.

Review the connected flow, not isolated styled fixtures: Library, real note, long scroll, editing/keyboard dismissal, file switching, Create, Today, Tags, Search, Settings, Comments and available intelligence actions, including their actual empty/offline/error states. Follow the [review gate](design-system.md#7-review-gate). Screenshots establish only the supplied presentation. Physical posture continuity, spoken VoiceOver, hardware performance/haptics and live-model quality remain separate until observed.
