# GistPad Native design

Owner: Designer. This is how GistPad looks, reads and moves. Behavior lives elsewhere: [sync.md](sync.md) for saving, publishing and status, the [Comments README](../Sources/Shared/Comments/README.md) for quotes and threads, [engineering.md](engineering.md) for structure, [capture-matrix.md](capture-matrix.md) for captures and [AGENTS.md](../AGENTS.md) for how a change ships.

## Direction

GistPad should feel like it shipped next to Notes. For every surface, ask what Notes does there first, then check Reminders and Journal. Use the system's role, placement and style. Every custom tint, size, font or animation earns its place or goes.

The personal touches are the original notebook icon, the user's tag colors and accent, and the web editor's syntax colors. Everything else is system. Liquid Glass belongs to bars, menus and controls. The page is opaque: no glass prose, painted gradients or blur imitations. Cached words show at once, typing is never delayed and nothing decorates a wait.

The web app sets what GistPad can do and how fast. It doesn't set the look.

## Words

- A **gist** is the whole thing on GitHub. A **file** is one file in it. A **daily note** is one day's file, and **today's note** is today's. Never call a gist a "note" or "source" on screen.
- **Publish** means sending to GitHub. Saving on the phone is never announced.
- Inserted pictures are **images**, never "photos", because they can be screenshots or anything else.
- Recovery buttons say **Try Again**.
- Every sign-in button says **Sign in with GitHub**, as text with no mark, cased like Apple's Sign in with Apple.
- `ContentUnavailableView` titles and alert titles are title case. Messages are sentence case and end with a period.
- Failures use `exclamationmark.circle`.
- Commands that open a dialog or sheet end with "…".
- Authored titles and emoji appear exactly as written.

## Layout

| Space | Layout |
| --- | --- |
| Closed Duo or a standard iPhone | The Library pushes one gist |
| Open Duo | The Library sidebar beside the gist |
| Split | Edit and Preview side by side, only when each pane gets at least 320 pt. The Library yields first |

Use size classes and the container's geometry, never device names. Respect the Duo's asymmetric safe areas. Folding or unfolding never changes the mode, the caret or Undo.

**Sheet buttons.** Every sheet closes with the system X in `.cancellationAction`: `Button(role: .cancel)` when closing throws away an edit, `Button(role: .close)` when there's nothing to lose. A sheet that saves confirms with `Button(role: .confirm)` in `.confirmationAction`, the system's blue glass checkmark. The roles supply the symbol, color and VoiceOver label, so neither sets text, an accessibility label, a tint or a button style. While saving, the checkmark becomes a `ProgressView`. Both stay visible while a field has focus, so on the Closed Duo they sit in the trailing rail like Comments' X. This covers Rename Gist…, Rename File…, Add File…, Add Link, Add to Today and the tag sheets.

Launch restores the last open file, or opens today's note. Existing files open in Preview. New gists and today's note open in Edit with the caret ready. The mode you pick sticks.

Opening a file:

- **Cached:** the real words at once, offline too. No skeleton, flash or previous file.
- **Uncached:** the title at once, then one plain `ProgressView` after 350 ms.
- **Failed:** **Couldn't Open This File**, the reason and Try Again. Preview's own failure says **Preview Unavailable**.

## Library

The title is the system large title **GistPad**, with the gist count as its subtitle ("12 gists"), collapsing on scroll. Compact width uses `.insetGrouped`, like Notes. The Open sidebar uses `.sidebar` with native neutral selection.

Sections run **Pinned**, then the date groups (**Today**, **Yesterday**, **Previous 7 Days**, **Previous 30 Days**, month names this year, then years), then **Daily Notes**, **Starred Gists** and **Archived Gists**. Empty sections don't render. Each gist appears once, so a pinned gist lives only in Pinned.

Headers use the system header font with `.headerProminence(.increased)` and a secondary count. Pinned and the last three get a leading monochrome `pin`, `calendar`, `star` or `archivebox`. Date groups are plain text. In compact width the whole header toggles its section, with Notes' trailing disc: `chevron.down.circle.fill` in `secondaryLabel`, swapping to `chevron.forward.circle.fill` with the symbol replace transition. The sidebar shows its own chevron instead. Pinned and the last three remember their state per account across launches, and date groups for the session. While filtering, matching sections open and can't collapse.

### Rows

| Part | Look |
| --- | --- |
| Title line | `.headline` title, with `star.fill` after it when starred. Trailing `.footnote` metadata: file count, comment count, then date |
| Tag line | Only when tagged, 6 pt below. Up to two tag labels, then `+N` in secondary text. The counts move to its trailing end |
| Counts | Secondary `.footnote`, each an inline glyph and number 8 pt apart (scaled): `doc.text` with the file count when a gist has two or more files, then `text.bubble` with the comment count when it has comments. A missing count leaves no gap. VoiceOver reads "3 files, 2 comments" |
| Date | `.secondary`, the one muted exception, like Notes. Time today, then Yesterday, the weekday this week, then a short date |
| Daily row | One line: the day ("Monday, Nov 2", with the year when it differs) and a task ring with `3/4`. Complete shows a green `checkmark.circle.fill`. An earlier day's unfinished tasks show in orange. No tags or counts |

No excerpts, thumbnails or cards. Vertical padding is 14 pt, scaled with Body, and the compact horizontal inset is 16 pt. At accessibility sizes the row stacks: title, metadata, then tags.

Swipe trailing for **Delete** (red, confirmed) and **Archive** or **Unarchive** (system gray). Swipe leading for **Pin** or **Unpin**. The context menu offers Open Comments, Pin, Archive and Delete.

### Search, filters and toolbars

Search is `.searchable`, matching titles. In compact width it uses `.searchToolbarBehavior(.minimize)`: a magnifier that expands in place. In the Open sidebar it's a full field at the bottom of the column, at rest and while searching, because a minimized button lands past the overlay sidebar's edge. Tags filter separately. While tags are selected, a strip above Pinned shows them as chips, the matching count in secondary ("3 gists") and an `xmark.circle.fill` **Clear Tag Filter** button. No tags, no strip. No matches shows `ContentUnavailableView.search`.

The compact toolbar has **New Gist**, **Today** and **Settings** at the top, and **Search** and **Tags** at the bottom, like Notes. Tags hides while searching, is disabled without tags and turns system blue while filtering, like a confirm button, keeping the outline `tag`. The Open sidebar keeps the same bottom: the Search field fills the column with **Tags** beside it, and **GitHub needs attention** sits between them when there's a problem. New Gist and Today sit in the rail, so **Settings** is the one button at the top, beside the sidebar toggle. Signed out, Settings is the only toolbar button. The library has no More menu. Pull to refresh.

| State | Title, message and action |
| --- | --- |
| Signed out | **Welcome to GistPad** / Your knowledge and daily notes, kept in GitHub gists. / Sign in with GitHub |
| No gists | **No Gists Yet** / A thought, a list, a little thing worth keeping. Start your first gist. / New Gist |
| Load failed | **Couldn't Load Your Gists** / the reason / Try Again |
| Sign-in lapsed | **Reconnect GitHub** / the reason / Sign in with GitHub |

### Today and Comments buttons

**Today** is a `calendar` toolbar toggle, tinted primary. It takes the system's on fill once today's note has a page, and a badge counting today's unfinished tasks, up to 99+. Zero or unknown shows no badge. VoiceOver says "Today, 3 unfinished tasks". **Comments** is the same kind of toggle with `text.bubble` and the comment count, filled while Comments is open. Both stay quiet: no accent, red or progress ring.

## The gist screen

**Title.** The gist's title, with the file name as its subtitle, except README.md. With more than one file, the title is a menu of files, the current one checked, then **Rename File…** and **Add File…**.

**Mode.** A segmented, icon-only picker: Edit `square.and.pencil`, Split `rectangle.split.2x1` (only when it fits) and Preview `eye`, each with its spoken name.

**Status.** Healthy editing shows nothing. **Publish** (`arrow.up.doc`) appears when autosave is off or a publish didn't land. **GitHub needs attention** (`exclamationmark`) opens a popover saying what's wrong, with **Reconnect GitHub**. No spinner, toast or save pill. [sync.md](sync.md#what-you-see) says what each means.

**More**, in native sections:

1. A compact row: Pin, Star, Share and Copy Link, which confirms with "Link copied". Share is the system share sheet, headed by the gist's title and the GistPad artwork. While Comments is a sheet on iPhone, Share hides, because the system can't present over it. Copy Link stays.
2. Rename Gist…, Tags, Files, Intelligence…, Find and Replace.
3. Open in GitHub.
4. Archive or Unarchive.
5. **Delete Gist…**, or **Delete Daily Note…** on a daily note.

**Delete.** Title **Delete “[title]”?** Message: **This deletes the gist from this iPhone and GitHub, including changes that haven't been published. This can't be undone.** A daily note says **the daily note** instead. Buttons Cancel and a destructive Delete. Deleting a daily note removes that day's file, or the gist when it's the last file.

**Review Changes.** A conflict opens a large sheet with Changes, My Draft and GitHub tabs. It says **Your draft is saved on this iPhone.** and **Both versions changed the same passage. Choose a version, or return to your draft to combine the changes yourself.** Changes labels its sides **On this iPhone** and **On GitHub**, with `+` and `-` and sideways scrolling. **Keep Mine** publishes yours. **Use GitHub's** confirms with **Replace your local draft with the GitHub version?** / "Replace your text with GitHub's version. You can undo this."

**Local save failure.** "Your latest changes couldn't be saved on this iPhone. Keep the editor open and retry the local save."

**Keyboard bar.** One floating `UIGlassEffect` capsule above the keyboard:

- **Aa:** Bold, Italic, Body, Heading 1 to 6.
- **Lists:** Bulleted, Numbered, Checklist, Increase Indent, Decrease Indent.
- **Insert:** Link…, Inline Code, Code Block, Quote, Image…
- **Intelligence** and **Hide Keyboard**.

Find is the system find bar, from More or Command-F.

**Images.** Insert → Image… opens the system picker, with no notice first. A toolbar `ProgressView` labeled "Uploading Image" shows during upload. Failure is **Couldn't Add Image** with Try Again and Cancel.

## Tags and Settings

The tag editor and filter are one family: searchable sheets at medium and large (large at accessibility sizes) with inline titles. The editor, **Tags**, has a Close that asks **Discard tag changes?** when there are edits, a checkmark Save, and Search and **New Tag** at the bottom. **Edit Tag…** lives in swipe and context menus. The tag form is **New Tag** or **Edit Tag**, with Tag name, Color, Use Default Color, a preview, **Delete Tag** and **Save Tag**. **Filter by tags** shows each tag's gist count in secondary before its check, whose space is always reserved, and **Clear tag filters**. Picker rows show a swatch, the name in `label` and a neutral check, never a tinted row.

Settings is a small Form:

- **Account.** Signed out shows **Connect GitHub**, "Sign in to open your GitHub gists, daily notes and saved tags." and **Sign in with GitHub**.
- **Writing.** Autosave While Writing, Check Spelling and Show Front Matter, with no footers.
- **Appearance.** Accent Color.
- **Switch GitHub Account**, then **Sign Out**, which confirms with **Sign Out?**

## Color and type

| Role | Color |
| --- | --- |
| Page | `systemBackground`, opaque |
| Ink | `label`, with `secondaryLabel` for metadata |
| Chrome | Primary monochrome, never the accent |
| Caret, selection, confirm buttons and the active Tags filter | System blue |
| Destructive | System red |
| Complete | System green |
| Overdue | System orange |
| Accent | The user's saved web accent, sky `#0EA5E9` by default |

The accent appears only in the widget's weekday and New Gist, Preview's accent details, comment highlights and its own Settings swatch. Text targets 4.5:1, and 7:1 with Increased Contrast.

**Tag labels** fill with the exact saved color at full opacity, with black or white ink, whichever contrasts more. `.footnote` medium, 8 by 4 pt padding, 8-pt corners. No dot, overlay or opacity. A missing color uses the neutral system fill. Increased Contrast adds a primary outline.

**Type** is SF through text styles. Code uses scaled system monospace. No bundled fonts, tracking or fixed sizes. At accessibility sizes, wrap and stack before shrinking.

## Editor

The editor shows exact Markdown, styled with attributes only: no hidden delimiters, smart quotes or reformatting. Insets are 24 pt top, 20 pt sides and 40 pt bottom, with soft scroll edges under the bars. Headings are Body-size bold. The web editor's colors mark headings, quotes, HTML and links, and system ink does the rest.

| Span | Light | Dark | Light Increased | Dark Increased |
| --- | --- | --- | --- | --- |
| Heading line including `#`, bold, italic | `label` | `#D2A8FF` | `label` | `#E6CCFF` |
| Quote line including `>` | `#22863A` | `#7EE787` | `#155D27` | `#B0F5B7` |
| HTML tag | `#116329` | `#7EE787` | `#0B4B1E` | `#B0F5B7` |
| URL, underlined | `#032F62` | `#A5D6FF` | `#02234A` | `#D1ECFF` |
| Link label and wikilink, underlined | URL color | `label` | URL color | `label` |
| Prose, code, front matter | `label` | `label` | `label` | `label` |
| List markers, task brackets, code fences | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` |

Inline markers like `**` and `` ` `` wear their span's style. Bold or italic inside a quote stays purple, like the web. Code and front matter are Body-size monospace. A proposed edit shows added words semibold and underlined, and removed words secondary and struck through.

## Preview

Preview renders the web's Markdown dialect with the app's type and colors.

| Metric | Value |
| --- | --- |
| Measure | 20-pt gutters, at most 64ch |
| Page | 24 pt top, 40 pt bottom |
| Body | 17-pt Body, 1.75em line height, 1.25em between paragraphs |
| Headings | H1 34 pt bold. H2 25.5 pt semibold, 3rem before. H3 21.25 pt semibold, 2rem before. Hairline rules under H1 and H2. Each grows with its text style |

| Element | Look |
| --- | --- |
| Tasks | Real checkboxes with 44-pt targets |
| Quotes | 3-pt leading rule, 16-pt inset, primary ink |
| Code | Body-size monospace on a quiet surface. Blocks scroll sideways, with no rainbow highlighting |
| Tables | Semibold header, horizontal rules, no zebra, sideways scrolling |
| Details | Quiet chevron, Body semibold, 44-pt rows |
| Alerts | Kind label, symbol and boundary |
| Calculations | The current result semibold on the selected surface, tabular numerals |
| Diagrams | Neutral nodes in Body type, scrolling instead of shrinking |
| Images | Fit to width, with a fallback offline |
| Footnotes, contents | Footnote style with backlinks. Contents is a compact disclosure |

No page-wide sideways scrolling, tap flash or hover-only controls.

## Apple Intelligence

A medium and large sheet opens from the keyboard bar or **More → Intelligence…**, with an **Ask**, **Edit** and **Review** segmented control. Ask prompts "Ask about this file", Edit "What would you like to change?" and Review says "Find errors and unclear wording." One button named for the action becomes **Stop** while it runs, over a plain phase line. Ask answers with citations and **Show in File**. Edit shows each change as Before and After, with added words semibold and underlined and removed words struck through, then one **Apply Edit**. Only task changes get a headline, like "Mark this task complete." Review lists comments. A read-only gist says "This gist is read-only. You can ask and review, but not apply changes." An unsupported device says "This device doesn't support Apple Intelligence." Edit on a file too long for one pass says "This file is too long to edit at once. Select a section and use Writing Tools." Failures show in the sheet with `exclamationmark.circle`.

## Comments

Comments belong to published gists, so daily notes and unpublished gists have no Comments button.

In compact width, Comments is a sheet at medium and large (large at accessibility sizes), and you can keep using the gist behind it at medium. In regular width it's a trailing inspector, 320 pt ideal, and the Library sidebar steps aside until it closes. The inline title is **Comments**, with the system close X.

Threads show newest first. Each comment has an avatar, a semibold author, a relative date and a selectable Markdown body with system links. Replies are disclosures indented 12 pt. The selected thread gets a 12-pt rounded tertiary surface and scrolls into view. **Reply**, **Show Passage**, **Show Full Quote** and **Show Less** are borderless secondary buttons with 44-pt targets. Your comments offer Edit and Delete, which confirms with **Delete [author]'s comment from GitHub?** / **Delete Comment**.

The composer sits in the bottom safe-area bar, like Messages: a growing interactive glass field with 22-pt corners and the reply or quote context inside it, beside a circular **Post** button. Post is `arrow.up`, `.glassProminent` in system blue, large, with Command-Return. The thread's bottom scroll edge is soft, so the field and Post float over the thread with no band or divider.

States: "Loading comments" shows only on a first load with nothing cached. Reopening Comments shows the loaded thread straight away and refreshes quietly, and pull to refresh uses the system spinner. Failures say "Comments couldn't be loaded" or "Couldn't reach GitHub. Check your connection and try again." with Try Again. An empty conversation is just the composer, with no message.

In the gist, a commented passage gets a 50% accent highlight and no underline. Selected text offers **Add Comment** in the edit menu. Tapping a highlight, or **View Comment**, opens its thread.

## Widgets and shortcuts

The **GistPad** widget is the app's front door, a launcher with three ways in: today's note, a recent gist or a new one. It shows no note content, so it reads the same whether today is prose or tasks. It comes in small and medium only, described as "Open today's note, a recent gist or start a new one." There's no large size. Widgets don't scroll, and a short library never changes the layout.

| Part | Look |
| --- | --- |
| Date | Calendar's date, top left: the weekday spelled out in uppercase `.caption` semibold in the accent, shortened to MON in small only when the full name doesn't fit, over the day in regular `.largeTitle` in `label`. It opens today's note in Edit. In both sizes it's the `widgetURL`, so any tap that misses a gist or New Gist opens Today, including the empty date column and the margins around it. VoiceOver reads "Today, Monday, November 2" |
| New Gist | `square.and.pencil` in `.title3` and the accent, plain, like Notes' compose button. Top right in small, optically on the margins. At the bottom of the left column in medium, with the square's bottom on the baseline of the third row's time, mirroring how the weekday's top meets the first title's top. It holds that spot with one or two gists. It starts a new gist in Edit |
| Recent gists | Newest edit first, counting edits on the phone, so a gist you just started leads before it publishes. Never daily notes or archived gists. A `.subheadline` semibold title in `label` over its `.footnote` time in `secondaryLabel`, dated like the gist list. Medium shows three, one line each, starting 20 pt after the date column, with a `Divider` centered in 10 pt between them. Small shows the newest at the bottom, wrapping to two lines. Titles are privacy sensitive |
| Few or none | Rows stay top-aligned at the same rhythm and leave space below. No gists shows "No recent gists" in `.subheadline` `secondaryLabel` where the first would sit, like Calendar's "No events today". Signed out shows the date and "Sign in with GitHub" there, with no New Gist |
| Color | The system widget background, with `label` and `secondaryLabel` ink. The weekday and New Gist are the only accent pieces and the only `.widgetAccentable()` ones, so a tinted Home Screen tints just those two. Clear goes all white |

At accessibility sizes, medium shows two gists and small drops the time rather than shrinking text. Medium's date column is exactly as wide as today's weekday at every size, always spelled out, and the list starts 20 pt after it, a little roomier than the widget's margin so it never feels cramped. The gap stays the same every day, so the date and list read as one unit, and the list moves only when the date changes at midnight. Titles that still don't fit truncate or hyphenate, the way Calendar's widget does. New Gist holds its corner at every size: the symbol grows only as far as the widget lets text grow, and its tap area is a fixed pad around the symbol, never a scaled frame, so its edges stay on the margins and level with the weekday in small.

The Home Screen and the Lock Screen get different widgets. The Home Screen gets the launcher, in color and with titles. The Lock Screen gets **Today**, one round `accessoryCircular` widget for the row under the clock, because that row sits beside Weather, Battery and Fitness in the Lock Screen's own tint, and its two corners usually hold the camera and flashlight. Today shows GistPad's notebook mark, the app icon's cover, spine, three writing lines and three tabs drawn as a one-color template image (`TodayMark`), at half the circle's height and centered on `AccessoryWidgetBackground`. It's the only place the mark appears outside the icon, and the one exception to the symbol rule below. It doesn't show the date, which the Lock Screen already shows right above it, or `calendar`, which reads as the Calendar app. It's described as "Open today's note." and VoiceOver reads "Today's note". A tap opens today's note in Edit, or sign-in when signed out. It shows nothing private and never changes, so it has no timeline to refresh.

Three controls work in Control Center, on the Lock Screen and from the Action button, in this order and in the system control style with no accent. **Add to Today** (`calendar.badge.plus`, "Capture a thought or task in today's note.") opens the capture sheet, which adds Text or a Task to today's note. Its failure says **Couldn't Add to Today**. **Open Today** (`calendar`, the Today button's symbol, "Open today's note.") opens today's note in Edit. **New Gist** (`square.and.pencil`, "Start a new gist.") opens a blank gist, exactly like the widget's New Gist. Each verb keeps one symbol across the widget, controls and Shortcuts: `calendar` opens Today, `calendar.badge.plus` adds to it and `square.and.pencil` starts a new gist. Open Today, Add to Today and New Gist are also Siri and Shortcuts actions. Spotlight finds gists, and `gistpad://today`, `gistpad://new` and gist links open through the normal opening states.

## Motion

Native navigation, sheets and list animation do the moving. Pin and unpin move rows with list motion, and header discs use the symbol replace transition. Never delay words or the caret for an animation. No confetti, page flips, entrance replays on refresh or haptics on save. Reduce Motion shows the settled state.

## Review

Designer signs off every visible surface from real captures, never from code. Captures are Dark at the default text size, on the Duo Closed and Open, from one named build, with the real keyboard, sheets and states. Any visible change, even inside a cleanup, shows the user a before and after capture before it merges. Accessibility sizes, Light, Increased Contrast, Reduce Transparency, Reduce Motion and Bold Text keep working through system styles, but aren't captured or validated. Verdicts are **Approved** or **Changes required**, naming the scope inspected.
