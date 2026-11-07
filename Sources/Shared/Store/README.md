# Store

The nouns and where they're kept: gists as GitHub returns them, the phone's
cache of them, drafts, the signed-in account and its preferences, the GitHub
client, photo uploads, and the fixture GitHub that tests run against. It has no
UI, and nothing here decides when to publish or refresh. That's the
[Model](../../Features/Model/README.md). [docs/sync.md](../../../docs/sync.md)
is the promise to the user. The only outside dependency is Supabase's `Auth`,
pinned in `Package.swift`.

Everything follows gistpad.dev's conventions exactly, so the web keeps working
with whatever the phone writes.

## Nouns

| Type | What it is |
|---|---|
| `Gist`, `Gist.File` | A gist and its files as GitHub returns them. |
| `GitHubUser` | A GitHub identity: a gist's owner, and the GitHub side of your account. |
| `GitHubVersion` | A file's text and revision as GitHub had it. A draft's `base` and `conflict` are both one. |
| `GistFileDraft` | One file's unpublished text, with `base`, `sent` and `conflict`. |
| `GistCache` | The phone's copy of your gists and the last text GitHub gave for each file you've opened. |
| `GistPadAccount` | Who's signed in: `github` and `preferences`. |
| `GistPadPreferences`, `Tag` | Tags, pins, accent and autosave, from the account's Supabase metadata. |
| `GitHubProblem` | Why GitHub couldn't be read or written: offline, reconnect or rejected. |
| `DailyNote` | One day's file in the `📆 Daily notes` gist, as the widget and Today button read it. |

## Account

`GistPadAccountStore` signs in with GitHub through Supabase, using PKCE, the
`gist` scope and `gistpad://auth-callback`. `Keychain` holds the Supabase
session and each account's GitHub token, available after first unlock and never
synced off this device. `connectedAccount()` restores at launch without the
network, and `refreshAccount()` fetches the latest metadata. An account whose
GitHub identity has no user ID throws `reconnectGitHub`. Pass only a publishable
or anon key.

`githubClient(accountID:)` and `imageStorage(accountID:)` are bound to one
account. A missing GitHub token is `reconnectGitHub`. Signing out keeps that
account's drafts on the phone.

## Preferences

Tags, pins and settings live in the account's Supabase metadata, the same place
the web keeps them. `update(_:accountID:)` folds `GistPadPreferences.Change`
values over the latest metadata and writes only the top-level keys that changed,
in one request, so a batch lands whole or not at all. Keys and fields GistPad
doesn't know pass through untouched, and a malformed shape throws instead of
being replaced. Supabase has no compare-and-swap, so a simultaneous web write
can still race.

## GitHub

`GitHubClient` lists owned and starred gists with the web's Markdown filters,
reads files, creates secret gists, and sends targeted file changes: content,
rename and delete. Stars use GitHub's star API, and archiving adds the web's
` [Archived]` suffix to the description. It also reads and writes gist comments.
Source bytes stay exact, including the U+2064 marker the web uses for an empty
file (`Gist.File.emptyContent`). Its session has no URL cache or cookies and
refuses redirects. `GitHubProblem(error)` sorts a failure: a 401 or an account
error is `.reconnect`, a file that isn't yours or is too large is `.rejected`,
and anything else is `.offline`.

## Drafts

`GistFileDraftStore` is a SwiftData store on the phone, with no CloudKit. The
app's `default-data-protection` entitlement gives it complete file protection.
It holds at most one `GistFileDraft` per account and file, from your first
keystroke until GitHub has the text. Every write commits before it returns, so
the editor may say a change is saved on this iPhone as soon as `save` does.

`base` is GitHub's text when you started typing, and a new gist or day has none.
`sent` is the text of a publish GitHub hasn't confirmed yet. `conflict` is
GitHub's newer text, once it moved past `base`. `isPublished` means GitHub has
exactly the draft's text with nothing sent or in conflict, and the store lets
such a draft go. So does `isDisposable`: a new gist with no name or writing.

`save(_:text:github:)` stores typing. `keep` stores a note before you type in
it, such as a gist you named. `apply(_:github:)` takes a `DraftEdit` from
outside the editor, such as Add to Today, and adds its text to the end only if
the draft hasn't changed since it was read.

Publishing steps through `recordSent`, `confirm` and `forgetSent`.
`compareWithGitHub` decides everything about GitHub's copy, for both opening a
note and publishing: a copy that matches the draft or its sent text is
confirmed, and any other change from `base` is a conflict, including a file
deleted on GitHub. `resolveConflict` makes GitHub's text the new base with the
text you chose. `join` makes a new day a file of the Daily notes gist, `rename`
follows a rename, `removeDrafts` forgets a gist or file deleted on GitHub, and
`discardLocalCopy` deletes a gist that's only on the phone.

## Cache

`GistCache` is one account's owned and starred gists, plus the text and
revision GitHub last gave for each file you've opened, so the library and its
files open instantly and offline. It loads and saves itself in the drafts'
SwiftData container. A cache from an earlier build doesn't decode, and the next
refresh rebuilds it.

## Daily notes

`DailyNote.Day` pins the date and time zone when an action starts.
`DailyNote(cache:drafts:)` reads a day from the cache and drafts for the widget,
and `FileTask` and `TaskProgress` read tasks with the web's markers.
`DraftEdit.addToToday` appends a paragraph or one task per line.

## Links and photos

`GistLinks(gist:filename:)` gives the gistpad.dev share link and the GitHub
link, and whether the gist is secret. A gist that isn't published has no link.

`ImageStorage.check(_:)` accepts an image under 50 MB, typed by its own bytes.
`upload(_:gistID:)` posts it to `assets/<gist>/<uuid>.<extension>` the way the web does and
returns its public URL, and `markdown(_:)` gives `![Image](url)`. Assets are
public even when the gist is secret, and there's no upload queue.

## Testing

`FixtureServer`, in debug builds, answers GitHub and Supabase from memory
through a `URLProtocol` session, so tests, previews and fixture launches run the
real clients. `accounts()` returns a `GistPadAccountStore` that signs in to it,
`requests` records every call, and `intercept` injects failures. Tests never
touch the real GitHub or Supabase.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter StoreTests
```
