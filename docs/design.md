# GistPad Native design

Owner: Designer. This is how GistPad looks, reads and moves. Behavior lives elsewhere: [sync.md](sync.md) for saving, publishing and status, the [Comments README](../Sources/Shared/Comments/README.md) for quotes and threads, [engineering.md](engineering.md) for structure, [capture-matrix.md](capture-matrix.md) for captures and [AGENTS.md](../AGENTS.md) for how a change ships.

## Direction

GistPad should feel like it shipped next to Notes. For every surface, ask what Notes does there first, then Reminders and Journal. Use the system's role, placement and style. Every custom tint, size, font or animation earns its place or goes.

The personal touches are the original notebook icon, the user's tag colors and accent, and the web editor's syntax colors. Everything else is system. The page is opaque: no glass prose, painted gradients or blur imitations. Cached words show at once, typing is never delayed and nothing decorates a wait.

The web app sets what GistPad can do and how fast. It doesn't set the look.

## Words

- A **gist** is the whole thing on GitHub. A **file** is one file in it. A **daily note** is one day's file, and **today's note** is today's. Never call a gist a "note" or "source" on screen. Siri's notes actions are the one exception, because "note" is the word you said to Siri.
- A **draft** is your unpublished text on this iPhone. **Publish** means sending to GitHub. Saving on the phone is never announced. **Autosave** is the web's name for publishing as you write, and it's the only place "save" means GitHub.
- GitHub reads are a **check for changes**, never "update" or "sync".
- **Show in File** (`text.viewfinder`) is the one name for jumping to a passage, from a comment or an Intelligence citation.
- **Comments** are GitHub's. Intelligence Review's private notes on passages are **suggestions**, never comments.
- Something that waits for GitHub says **You can [verb] after this gist publishes.**
- A busy editor says **Finish typing or wait for Writing Tools, then try again.** Text that moved under a selection says **This file changed. Select the text again.**
- Inserted pictures are **images**, never "photos".
- Recovery buttons say **Try Again**.
- Every sign-in button says **Sign in with GitHub**, as text with no mark, cased like Apple's Sign in with Apple.
- Buttons, `ContentUnavailableView` titles and alert titles are title case. An alert title that asks a question is a sentence, like **Discard tag changes?** Messages are sentence case, end with a period and use contractions, never "cannot".
- Failures use `exclamationmark.circle`.
- Menu items and buttons never end with "…", even when they open a dialog or sheet. Progress text like "Answering…" keeps it.
- Authored titles and emoji appear exactly as written.

## Layout

| Space | Layout |
| --- | --- |
| Closed Duo or a standard iPhone | The Library pushes one gist |
| Open Duo | The Library sidebar beside the gist |
| Split | Edit and Preview side by side in your own gist, only when each pane gets at least 320 pt and Comments is closed |

Use size classes and the container's geometry, never device names. Folding or unfolding keeps the caret and Undo, and Split comes back when there's room for it.

**Sheet buttons.** Every sheet closes with the system X in `.cancellationAction`: `Button(role: .cancel)` when closing throws away an edit, `Button(role: .close)` when there's nothing to lose. A sheet that saves confirms with `Button(role: .confirm)` in `.confirmationAction`, the system's blue checkmark. Neither sets text, a label, a tint or a style, because the role supplies them. While saving, the checkmark becomes a `ProgressView`. Both stay visible while a field has focus. This covers Rename Gist, Rename File, Add File, Add Link, Add to Today and the tag sheets.

Launch restores the last open file. With none, nothing opens, because today's note only starts when you ask for it. A file opens in the mode you picked last, Split at first. Where Split doesn't fit, it opens in the last of Edit or Preview you picked, Preview at first. A new gist, and today's note opened from Today, start with the caret at the end. Otherwise Edit waits for a tap before it raises the keyboard. A new gist's row appears, selected, with your first keystroke. Leave one untyped and it closes without a trace, like an empty note in Notes.

Opening a file:

- **Cached:** the real words at once, offline too. No skeleton, flash or previous file.
- **Uncached:** its bar at once, sliding in with the push, then one plain `ProgressView` after 350 ms. The words arrive under a bar that doesn't change.
- **Failed:** **Couldn't Open This File**, the reason and Try Again. Preview's own failure says **Preview Unavailable**.

## Library

The title is the system inline title **GistPad**, with the gist count as its subtitle ("12 gists"). Compact width uses `.insetGrouped`, like Notes.

Sections run **Pinned**, then the date groups (**Today**, **Yesterday**, **Previous 7 Days**, **Previous 30 Days**, month names this year, then years), then **Daily Notes**, **Starred Gists** and **Archived Gists**. Empty sections don't render. Each gist appears once, so a pinned gist lives only in Pinned.

Headers use `.headerProminence(.increased)` with a secondary count. Pinned and the last three get a leading monochrome `pin`, `calendar`, `star` or `archivebox`, and date groups are plain text. In compact width the whole header toggles its section, with Notes' trailing disc: `chevron.down.circle.fill` in `secondaryLabel`, swapping to `chevron.forward.circle.fill` with the symbol replace transition. Pinned and the last three remember their state per account across launches, and date groups for the session. While filtering, matching sections open and can't collapse.

### Rows

| Part | Look |
| --- | --- |
| Title line | `.headline` title, with `star.fill` after it when starred. Trailing `.footnote` metadata: file count, comment count, then date |
| Tag line | Only when tagged, 6 pt below. Up to two tag labels, then `+N` in secondary text. The counts move to its trailing end |
| Counts | Secondary `.footnote`, each an inline glyph and number 8 pt apart (scaled): `doc.text` with the file count when a gist has two or more files, then `text.bubble` with the comment count when it has comments. A missing count leaves no gap. VoiceOver reads "3 files, 2 comments" |
| Date | `.secondary`, the one muted exception, like Notes. Time today, then Yesterday, the weekday this week, then a short date |
| Daily row | One line: the day ("Monday, Nov 2", with the year when it differs) and a task ring with `3/4`. Complete shows a green `checkmark.circle.fill`. An earlier day's unfinished tasks show in orange. No tags or counts |

No excerpts, thumbnails or cards. Vertical padding is 14 pt, scaled with Body, and the compact horizontal inset is 16 pt. At accessibility sizes the row stacks: title, metadata, then tags.

Swipe trailing for **Delete** and **Archive** or **Unarchive**, and leading for **Pin** or **Unpin**. Swipe actions show only their symbols, as in Mail. Every one of these buttons shows what tapping does, never the gist's current state: `pin` and `pin.slash`, `star` and `star.slash`, `archivebox` and `arrow.up.bin`, in swipes, the context menu and More. The context menu offers Open Comments, Pin, Archive and Delete. Revealing a Delete, by swipe or by Edit's red minus, is its own confirmation, so it deletes at once. The context menu's Delete confirms, because one tap reaches it. A daily note is a file, not a gist, so it only offers Delete. A pin, star or archive that doesn't go through shows the standard alert with the system's reason, and nothing retries it.

### Search, filters and toolbars

Search is one `.searchable(placement: .toolbar)` on the library list, matching titles. In compact width it minimizes to a magnifier that expands in place. In the Open sidebar it's a full field at the bottom of the column, because a minimized button lands past the sidebar's edge. Tags filter separately. While tags are selected, a strip above Pinned shows them as chips, the matching count in secondary ("3 gists") and an `xmark.circle.fill` **Clear Tag Filter** button. No matches shows `ContentUnavailableView.search`.

The system **Edit** button leads the top of the Library in both layouts, giving each gist you own a red minus that reveals its Delete. The compact toolbar has **New Gist**, **Today** and **Settings** at the top, and Search and **Filter by Tags** at the bottom, like Notes. The filter keeps the outline `tag`, hides while searching, is disabled without tags and turns system blue while filtering. When there's a problem, **GitHub needs attention** sits between Search and the filter in both layouts. In the Open sidebar, New Gist and Today sit in the rail, so Edit and Settings are the only buttons at the top. Signed out, Settings is the only toolbar button. The library has no More menu.

| State | Title, message and action |
| --- | --- |
| Signed out | **Welcome to GistPad** / Your knowledge and daily notes, kept in GitHub gists. / Sign in with GitHub |
| No gists | **No Gists Yet** / A thought, a list, a little thing worth keeping. Start your first gist. / New Gist |
| Load failed | **Couldn't Load Your Gists** / GitHub couldn't be reached. Your gists will appear once it answers. / Try Again |
| Sign-in lapsed | **Reconnect GitHub** / Sign in with GitHub again to see your gists. / Sign in with GitHub |

When one of these explains a problem, **GitHub needs attention** stays out of the toolbar, so the problem is said once. With gists still listed, or while a filter or search shows nothing, the toolbar control carries it.

### Today and Comments buttons

**Today** is a `calendar` toolbar toggle, tinted primary. It takes the system's on fill once today's note has a page, and a badge counting today's unfinished tasks, up to 99+. Zero or unknown shows no badge. VoiceOver says "Today, 3 unfinished tasks". **Comments** is the same kind of toggle with `text.bubble` and the comment count, filled while Comments is open. Neither uses the accent, red or a progress ring. The count is our own small neutral badge, because on iOS 27.2 the system's toolbar `.badge` stays red even with `.badgeProminence(.decreased)`, and a toggle doesn't show it at all.

## The gist screen

**Title.** The title floats at the leading end of the bar: the gist's title in `.headline` over its file name in `.caption` `secondaryLabel`, one line each, with no file name for README.md. Every title is the same glass capsule with no chevron, in every gist, every daily note and every state. In a gist it's a `Menu` with its indicator hidden. In your own gist the menu lists the files, the current one checked, when there are two or more, then **Rename File** and **Add File**. In someone else's gist it lists just the files, even when there's one. VoiceOver reads the title, then the file name. A daily note's capsule holds its day exactly as its row reads ("Friday, Nov 6"), with no file name and no menu, and reads as a heading. You move between days in the Daily Notes section, like the web. The title is never wider than "🤖 Coding Agent Culture" set in its own `.headline`, so the cap grows with Dynamic Type. Shorter titles hug their text, and longer ones end in "…" inside the capsule, as does a long file name. The cap is the same in every posture, so the capsule never moves into the overflow menu and never pushes Mode, Comments or More there. The page's scroll edges are soft in every mode, so words blur under the floating title and buttons with no bar or hairline. A note that's opening is already its own screen, with its capsule, Mode, Comments and More from the first frame of the push, so nothing in the bar changes when it arrives. One that can't open keeps the same capsule.

**Mode.** In your own gist, a segmented, icon-only picker: Edit `square.and.pencil`, Split `rectangle.split.2x1` (only when it fits) and Preview `eye`. Someone else's gist shows only Preview, with no picker.

**Status.** Healthy editing shows nothing, and there's no Publish button. A conflict or a lapsed sign-in puts **GitHub needs attention** (`exclamationmark`) in the bar, and it opens Review Changes or reconnects. When a check for changes fails, the same control sits at the bottom and opens a popover headed "Couldn't check for changes", with the reason and **Try Again** or **Reconnect GitHub**. No spinner, toast or save pill. [sync.md](sync.md#what-you-see) says what each means.

**More**, in native sections:

1. A compact row: Pin, Star, Share and Copy Link, which VoiceOver confirms with "Link copied". Share is the system share sheet, headed by the gist's title and the GistPad artwork. While Comments is a sheet on iPhone, Share hides, because the system can't present over it. Copy Link stays.
2. Rename Gist, Tags, Intelligence, Find and Replace. Files live only in the title.
3. Archive or Unarchive.
4. **Delete Gist**, or **Delete Daily Note** on a daily note.

A daily note leaves out everything that acts on the gist: Pin, Star, Rename Gist, Tags and Archive. Its Share is headed by the day.

**Delete.** Title **Delete “[title]”?** Message: **This deletes the gist from this iPhone and GitHub, including changes that haven't been published. This can't be undone.** A daily note is titled by its day, **Delete “Friday, Nov 6”?**, and says **the daily note** instead of the gist.

**Review Changes.** A conflict opens a sheet with Changes, My Draft and GitHub tabs. It says **Your draft is saved on this iPhone.** and **Both versions changed the same passage. Choose a version, or return to your draft to combine the changes yourself.** Changes labels its sides **My Draft** and **GitHub**, like the tabs, with `+` and `-` and sideways scrolling. **Keep Mine** publishes yours. **Use GitHub's** confirms with **Replace your draft with GitHub's version?** / "You can undo this."

**Local save failure.** "Your latest changes couldn't be saved on this iPhone. Keep this file open and try again."

**Keyboard bar.** One floating `UIGlassEffect` capsule above the keyboard:

- **Text Style:** Bold, Italic, Body, Heading 1 to 6.
- **Lists:** Bulleted List, Numbered List, Checklist, Increase Indent, Decrease Indent. Swipe right on a list line to indent it and left to outdent it, like Notes, without raising the keyboard or moving the caret.
- **Insert:** Link, Inline Code, Code Block, Quote, Image.
- **Intelligence** and **Hide Keyboard**.

**Images.** Insert → Image opens the system picker, with no notice first. A toolbar `ProgressView` labeled "Uploading Image" shows during upload. Failure is **Couldn't Add Image** with Try Again and Cancel.

## Tags and Settings

The tag editor and filter are one family: searchable sheets at medium and large (large at accessibility sizes) with inline titles. The editor, **Tags**, has a Close that asks **Discard tag changes?** when there are edits, a checkmark Save, and Search and **New Tag** at the bottom. **Edit Tag** (`pencil`) lives in swipe and context menus, and its swipe is icon-only like the gist list's. The tag form is **New Tag** or **Edit Tag**, with Tag name, Color, Use Default Color, a preview and **Delete Tag**, and saves with its checkmark. **Filter by Tags** shows each tag's gist count in secondary before its check, whose space is always reserved, and **Clear Tag Filter**, the same words as the strip's button. Picker rows show a swatch, the name in `label` and a neutral check, never a tinted row.

Settings is a small Form:

- **Account.** Signed in shows your avatar, name and `@login`, with **Sign Out** right under it as a destructive `Label` with `rectangle.portrait.and.arrow.forward`, icon and title both system red, confirmed by **Sign Out?** A Form's destructive role reddens only the title, so the icon takes `.red` to match. There's no account switching: sign out, then sign in. Signed out shows **Connect GitHub**, "Sign in to open your GitHub gists, daily notes and saved tags." and **Sign in with GitHub**.
- **Writing.** Autosave While Writing, Check Spelling and Show Front Matter, with no footers.
- **Appearance.** Accent Color.

## Color and type

| Role | Color |
| --- | --- |
| Chrome | Primary monochrome, never the accent |
| Caret, selection, confirm buttons and the active Tags filter | System blue |
| Complete | System green |
| Overdue | System orange |
| Accent | The user's saved web accent, sky `#0EA5E9` by default |

The accent appears only in the widget's weekday and New Gist, a few Preview details, comment highlights, the rule beside a comment's quote and its own Settings swatch. Text targets 4.5:1, and 7:1 with Increased Contrast.

**Tag labels** fill with the exact saved color at full opacity, with black or white ink, whichever contrasts more. `.footnote` medium, 8 by 4 pt padding, 8-pt corners. No dot, overlay or opacity. A missing color uses the neutral system fill. Increased Contrast adds a primary outline.

**Type** is SF through text styles. Code uses scaled system monospace. No bundled fonts, tracking or fixed sizes. At accessibility sizes, wrap and stack before shrinking.

## Editor

The editor shows exact Markdown, styled with attributes only: no hidden delimiters, smart quotes or reformatting. `()`, `[]` and `{}` pair as you type, and typing the closer steps over it. Insets are 24 pt top, 20 pt sides and 40 pt bottom. Headings are Body-size bold. The web editor's colors mark headings, quotes, HTML and links, and system ink does the rest.

| Span | Light | Dark | Light Increased | Dark Increased |
| --- | --- | --- | --- | --- |
| Heading line including `#`, bold, italic | `label` | `#D2A8FF` | `label` | `#E6CCFF` |
| Quote line including `>` | `#22863A` | `#7EE787` | `#155D27` | `#B0F5B7` |
| HTML tag | `#116329` | `#7EE787` | `#0B4B1E` | `#B0F5B7` |
| URL, underlined | `#032F62` | `#A5D6FF` | `#02234A` | `#D1ECFF` |
| Link label and wikilink, underlined | URL color | `label` | URL color | `label` |
| Prose, code, front matter | `label` | `label` | `label` | `label` |
| List markers, task brackets, code fences | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` | `secondaryLabel` |

Inline markers like `**` and `` ` `` wear their span's style. Bold or italic inside a quote stays purple, like the web. Code and front matter are Body-size monospace.

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
| Footnotes, contents | Footnote style with backlinks. Contents is a compact disclosure. A contents link or backlink lands its target 16 pt under the bar |

No page-wide sideways scrolling, tap flash or hover-only controls.

## Apple Intelligence

A medium and large sheet opens from the keyboard bar or **More → Intelligence**, with an **Ask**, **Edit** and **Review** segmented control. Ask prompts "Ask about this file", Edit "What would you like to change?" and Review says "Find errors and unclear wording." One button named for the action becomes **Stop** while it runs, over a row naming the step with a spinner, like "Reading part 2 of 3…". Ask answers with citations and **Show in File**. Edit shows each change as Before and After, with added words semibold and underlined and removed words secondary and struck through, then one **Apply Edit**. With nothing to change it says "No changes needed." Only task changes get a headline, like "Mark this task complete." Review lists suggestions under a "3 suggestions" header, or says "No suggestions." A read-only gist says "This gist is read-only. You can ask and review, but not apply changes." An unsupported device says "This device doesn't support Apple Intelligence." Failures show in the sheet with `exclamationmark.circle`.

## Comments

Comments belong to published gists, so daily notes and unpublished gists have no Comments button.

In compact width, Comments is a sheet at medium and large (large at accessibility sizes), and you can keep using the gist behind it at medium. In regular width it's a trailing inspector, 320 pt ideal, and the Library sidebar steps aside until it closes. The inline title is **Comments**.

Threads show newest first. Each comment has an avatar, a semibold author, a relative date and a selectable Markdown body with system links. Replies are disclosures indented 12 pt. The selected thread gets a 12-pt rounded tertiary surface and scrolls into view. **Reply**, **Show in File**, **Show Full Quote** and **Show Less** are borderless secondary buttons with 44-pt targets. A quote that can't be found says "Not found in this file". The composer's clear button reads **Cancel Reply**, **Remove Quote** or **Cancel Editing**. Your comments offer Edit and Delete, which confirms with **Delete [author]'s comment from GitHub?** / **Delete Comment**.

The composer sits in the bottom safe-area bar, like Messages: a growing interactive glass field with 22-pt corners and the reply or quote context inside it, beside a circular **Post** button. Post is `arrow.up`, `.glassProminent` in system blue, large, with Command-Return. The thread's bottom scroll edge is soft, so the field and Post float over the thread with no band or divider.

States: "Loading comments" shows only on a first load with nothing cached. Reopening Comments shows the loaded thread straight away and refreshes quietly. Failures say "Comments couldn't be loaded" or "Couldn't reach GitHub. Check your connection and try again." with Try Again. A post or edit that doesn't go through says "Your comment couldn't be posted." A delete says "This comment couldn't be deleted.", because it can be someone else's on your gist. Both go on "Check your connection and try again." An empty conversation is just the composer, with no message.

In the gist, a commented passage gets a 50% accent highlight and no underline. The highlight stays put while you type. Selected text offers **Add Comment** in the edit menu. Tapping a highlight, or **View Comment**, opens its thread.

## Widgets and shortcuts

The **GistPad** widget is a launcher with three ways in: today's note, a recent gist or a new one. It shows no note content. It comes in small and medium only, described as "Open today's note, a recent gist or start a new one." Widgets don't scroll, and a short library never changes the layout.

| Part | Look |
| --- | --- |
| Date | Calendar's date, top left: the weekday spelled out in uppercase `.caption` semibold in the accent, shortened to MON in small only when the full name doesn't fit, over the day in regular `.largeTitle` in `label`. Any tap that misses a gist or New Gist opens today's note in Edit. VoiceOver reads "Today, Monday, November 2" |
| New Gist | `square.and.pencil` in `.title3` and the accent, plain, like Notes' compose button. Top right in small, optically on the margins. At the bottom of the left column in medium, with the square's bottom on the baseline of the third row's time. It starts a new gist in Edit |
| Recent gists | Newest edit first, counting edits on the phone, so a gist you just started leads. Never daily notes or archived gists. A `.subheadline` semibold title in `label` over its `.footnote` time in `secondaryLabel`, dated like the gist list. Medium shows three, one line each, with a `Divider` centered in 10 pt between them. Small shows the newest at the bottom, wrapping to two lines. Titles are privacy sensitive |
| Few or none | Rows stay top-aligned at the same rhythm and leave space below. No gists shows "No recent gists" in `.subheadline` `secondaryLabel` where the first would sit. Signed out shows the date and "Sign in with GitHub" there, with no New Gist. When the widget can't read the library, it says "Open GistPad to refresh" |
| Color | The system widget background, with `label` and `secondaryLabel` ink. The weekday and New Gist are the only accent and `.widgetAccentable()` pieces |

Medium's date column is exactly as wide as today's weekday at every size, always spelled out, and the list starts 20 pt after it, so the list moves only at midnight. At accessibility sizes, medium shows two gists and small drops the time rather than shrinking text. Titles that still don't fit truncate or hyphenate, like Calendar's widget. New Gist holds its corner at every size: the symbol grows only as far as the widget lets text grow, and its tap area is a fixed pad around the symbol, so its edges stay on the margins and level with the weekday in small.

The Lock Screen gets **Today**, one round `accessoryCircular` widget for the row under the clock. It shows GistPad's notebook mark, the app icon's cover, spine, three writing lines and three tabs drawn as a one-color template image (`TodayMark`), at half the circle's height and centered on `AccessoryWidgetBackground`. It's the only place the mark appears outside the icon, and the one exception to the symbol rule below. It shows no date, which the Lock Screen already shows, and no `calendar`, which reads as Calendar. It's described as "Open today's note." and VoiceOver reads "Today's note". A tap opens today's note in Edit, or sign-in when signed out.

Three controls work in Control Center, on the Lock Screen and from the Action button, in this order and in the system control style with no accent. **Add to Today** (`calendar.badge.plus`, "Capture a thought or task in today's note.") opens the capture sheet, which adds Text or a Task to today's note. Its failure says **Couldn't Add to Today**. **Open Today** (`calendar`, "Open today's note.") opens today's note in Edit. **New Gist** (`square.and.pencil`, "Start a new gist.") opens a blank gist, exactly like the widget's New Gist. Each verb keeps its symbol across the widget, controls and Shortcuts. Open Today, Add to Today and New Gist are also Siri and Shortcuts actions. Spotlight finds gists, and `gistpad://today`, `gistpad://new` and gist links open through the normal opening states.

## Motion

Native navigation, sheets and list animation do the moving, and pin and unpin move rows with list motion. Never delay words or the caret for an animation. No confetti, page flips or entrance replays on refresh. The only haptics are a light tap when a swipe indents a line and a success tap when an edit applies. Reduce Motion shows the settled state.

## Review

Designer signs off every visible surface from Dark captures, as [AGENTS.md](../AGENTS.md#how-a-change-ships) says. Accessibility sizes, Light, Increased Contrast, Reduce Transparency, Reduce Motion and Bold Text come from system styles and aren't captured.
