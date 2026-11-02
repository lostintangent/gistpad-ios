# GistPadSync

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

`DraftStore` is a SwiftData store on the phone, with complete file protection
and no CloudKit. It holds one `Draft` per account and file. Every write commits
before it returns, so the editor may say a change is saved on this iPhone as
soon as `persist` does.

A draft's `generation` increases with every edit, and `persist` rejects an
older one. `apply(_:)` takes a `DraftEdit` from outside the editor, such as a
widget's task toggle or Add to Today, and lands it only if the text it expects
is still there.

`baseContent` is GitHub's text the draft started from. `hasUnpublishedEdits`
compares against it, and a new gist or file has no base until it publishes.
`isDiscardableBlank` is true only for a new gist that's untitled and
whitespace-only, which `discardBlankDraft` removes when you leave it. Today's
note is never discardable, because opening it creates it.

`inspectRemoteChange` and `refreshCleanDraft` take on GitHub's newer text when
you have no edits, and record a `DraftConflict` when both sides changed.
`resolveConflict` makes GitHub's text the new base after the editor applies the
chosen text as one undoable edit. `updateDraftMetadata` follows a rename,
`removeDrafts` forgets a gist or file that GitHub deleted, and
`discardLocalCopy` deletes a gist that's only on the phone.

## Publishing

`DraftPublisher` sends one draft at a time for the account. It reads GitHub's
copy first. A match is acknowledged, a clean draft takes GitHub's text, and a
changed base becomes a conflict. Before sending, it records the attempted text
and generation, so a publish cut off by a dropped connection or a quit checks
GitHub before sending again. An edit that landed is acknowledged, and a create
looks for its gist by description and file bytes, so it never posts twice.
Typing during a publish stays unpublished for the next one.

Failures persist as `PublishState`. Network and HTTP failures can be retried, a
401 is `.reconnect`, and `Retry-After` is honored. An acknowledged publish
updates the library cache in the same commit as the draft.

When to publish belongs to the app: five seconds after typing stops, leaving a
file, leaving the app, and the sweep at launch and return. GitHub has no
conditional write, so the fresh read narrows a race with the web but can't
close it.

## Daily notes

`DailyNotes.stageToday(target:)` returns today's file, ready to edit. That's
your draft if you've started the day, else a new file in the `📆 Daily notes`
gist from `template.md` with `{{date}}` filled in, else the first day of a new
daily gist with a `# YYYY-MM-DD` heading. Staging only reads, but the new day
has no base, so the app publishes it whether or not you type. An earlier day
that never reached GitHub publishes first, so it creates the gist today joins.

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
  swift test --package-path Packages/GistPadSync
```
