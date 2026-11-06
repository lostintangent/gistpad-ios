# Sync

GistPad's data layer: GitHub sign-in through Supabase, the Gists client, account
preferences, drafts on the phone, publishing, conflicts, daily notes, the library
cache, photo uploads, and the fixture GitHub that tests run against. It has no UI.
[docs/sync.md](../../docs/sync.md) is the promise to the user, and this package
keeps it. The only outside dependency is Supabase's `Auth`, pinned in
`Package.swift`.

Everything follows gistpad.dev's conventions exactly, so the web keeps working
with whatever the phone writes.

## Account

`AccountStore` signs in with GitHub through Supabase, using PKCE, the `gist`
scope and `gistpad://auth-callback`. `Keychain` holds the Supabase session and
each account's GitHub token, available after first unlock and never synced off
this device. `connectedAccount()` restores at launch without the network, and
`refreshAccount()` fetches the latest metadata. Pass only a publishable or anon
key.

`githubClient(accountID:)` and `photoStorage(accountID:)` are bound to one
account. They throw `accountChanged` after a switch or sign-out, and a missing
GitHub token is `reconnectGitHub`. Signing out keeps that account's drafts on
the phone.

## Preferences

Tags, pins and settings live in the account's Supabase metadata, the same place
the web keeps them. `update(_:accountID:)` folds `Preferences.Change` values
over the latest metadata and writes only the top-level keys that changed, in one
request, so a batch lands whole or not at all. Keys and fields GistPad doesn't
know pass through untouched, and a malformed shape throws instead of being
replaced. Supabase has no compare-and-swap, so a simultaneous web write can
still race.

## GitHub

`GitHubClient` lists owned and starred gists with the web's Markdown filters,
reads files, creates secret gists, and sends targeted file changes: content,
rename and delete. Stars use GitHub's star API, and archiving adds the web's
` [Archived]` suffix to the description. It also reads and writes gist comments
for the Comments sheet. Source bytes stay exact, including the U+2064 marker the
web uses for an empty file (`GistFile.emptyContent`). Its session has no URL
cache or cookies and refuses redirects.

## Drafts

`DraftStore` is a SwiftData store on the phone, with no CloudKit. The app's
`default-data-protection` entitlement gives it complete file protection. It
holds one `Draft` per account and file. Every write commits before it returns,
so the editor may say a change is saved on this iPhone as soon as `persist`
does.

A draft's `generation` increases with every edit, and `persist` rejects an older
one. `apply(_:)` takes a `DraftEdit` from outside the editor, such as Add to
Today or a shortcut, and adds its text to the end only if the draft hasn't
changed since it was read.

`base` is GitHub's text when you started typing. `hasUnpublishedEdits`
compares against it, and a new gist or file has no base until it publishes.
`sent` is the text of a publish GitHub hasn't confirmed yet. `isPublished`
means GitHub has exactly the draft's text, with nothing sent and unconfirmed.
A published draft's state reads `.savedToGitHub`, and any other draft
without a problem reads `.savedLocally`, so the store never has to keep the two
in step. `.savingToGitHub` is never stored, because only the editor knows a
publish is running.

`isDiscardableBlank` is true for a new gist that's untitled and whitespace-only,
and for a day that was never typed in (generation 0), whatever it started from.
Neither has reached GitHub, and `discardBlankDraft` removes either when you
leave it.

`refreshPublishedDraft` takes on GitHub's newer text when the draft is
published. `compareWithGitHub` decides everything else about GitHub's copy, for
both opening a note and publishing. A copy that matches the draft or its sent
text is confirmed, and any other change becomes a `DraftConflict`, including a file
deleted on GitHub. `resolveConflict` makes GitHub's text the new base after the
editor applies the chosen text as one undoable edit. `updateDraftMetadata`
follows a rename, `removeDrafts` forgets a gist or file that GitHub deleted, and
`discardLocalCopy` deletes a gist that's only on the phone.

## Publishing

`DraftPublisher` sends one draft at a time for the account. A published draft
has nothing to send, so newer text on the web reaches it when the note is
opened. Otherwise it reads GitHub's copy and asks `compareWithGitHub`. Sending
records `sent` first, so a publish cut off by a dropped connection or a quit
checks GitHub before sending again. Sent text that landed is confirmed, and a
create looks for its gist by description and file bytes, so it never posts
twice. Typing during a publish stays unpublished for the next one. Typing after
a cut-off publish is `.savedLocally` again, even back to the base text, because
GitHub may hold the sent text.

Failures persist as `PublishState`. Network and HTTP failures wait for the next
publish moment, and a 401 is `.reconnect`. A confirmed publish updates the
library cache in the same commit as the draft.

When to publish belongs to the app: five seconds after typing stops, leaving a
file, leaving the app, and the sweep at launch and return. GitHub has no
conditional write, so the fresh read narrows a race with the web but can't close
it.

## Daily notes

`DailyNotes.stageToday(target:)` returns today's file, ready to edit. That's
your draft if you've started the day, without asking GitHub. Otherwise it reads
the daily gist from GitHub, by the cached library's ID when there is one,
because the web may have started today since the cache was written. Then it's
the web's file for today, else a new file in the `📆 Daily notes` gist from
`template.md` with `{{date}}` filled in, else the first day of a new daily gist
with a `# YYYY-MM-DD` heading. Offline, the cache's answer stands. Staging
only reads, and the new day publishes once you type in it. An earlier day that
never reached GitHub publishes first, so it creates the gist today joins. A
first day's publish joins the daily gist GitHub has, if the web started one
since this iPhone last saw the list.

`DailyNote.Day` pins the date and time zone when an action starts. `DailyNote`
reads a day from the cache and drafts for the widget, and `FileTask` and
`TaskProgress` read tasks with the web's markers. `DraftEdit.addToToday`
appends a paragraph or one task per line.

## Library cache

`cacheLibrary`, `cacheGist` and `cacheContent` keep the last complete list, gist
details and file text for each account, and `cachedLibrary(accountID:)` reads
them back, so the library and its files open instantly and offline. Cache only a
successful, complete refresh.

## Links and photos

`GistLinks(gist:filename:)` gives the gistpad.dev share link and the GitHub
link, and whether the gist is secret. A gist that isn't published has no link.

`PhotoStorage.png(from:)` makes an upright PNG without location or EXIF data,
up to 50 MB and 100 megapixels. `upload(_:gistID:)` posts it to
`assets/<gist>/<uuid>.png` the way the web does and returns its public URL, and
`markdown(_:)` gives `![Image](url)`. Assets are public even when the gist is
secret, and there's no upload queue.

## Testing

`FixtureServer`, in debug builds, answers GitHub and Supabase from memory
through a `URLProtocol` session, so tests, previews and fixture launches run the
real clients. `accounts()` returns an `AccountStore` that signs in to it,
`requests` records every call, and `intercept` injects failures. Tests never
touch the real GitHub or Supabase.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SyncTests
```
