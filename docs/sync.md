# How sync works

## Nouns

- **GitHub** is the truth. Gists hold files, and files hold text.
- **Cache** is the phone's copy of GitHub: the gist list, plus the text of today's note and of each file you've opened.
- **Draft** is one file's unpublished text, plus two more texts:
  - **base** is GitHub's text when you started typing. A new gist or a new day has none.
  - **sent** is the text of a publish GitHub hasn't confirmed yet.

## Rules

- You see the draft if there is one, and otherwise the cache.
- A file has at most one draft.
- Typing creates a draft, and it's deleted once GitHub has its text.
- Only Publish writes a file's text to GitHub.
- Cache and drafts belong to the signed-in account.

## Verbs

- **Refresh:** cache ← GitHub. The list and each file refresh at most once every 5 minutes, and a failed refresh tries again at the next chance.
- **Save:** draft ← your text. The first keystroke creates the draft, with base ← what you were looking at.
- **Publish:** if GitHub has the base, sent, or already your text, then sent ← your text and GitHub ← sent. When GitHub confirms, cache ← GitHub, base ← sent, and the draft is deleted unless you typed since. If GitHub has anything else, it's a conflict.
- **Delete:** the gist or file leaves GitHub, the cache and the phone.

## Scenarios

### Launch
- First time: sign in with GitHub, then Refresh.
- After that: show the cache, Refresh, Publish any leftover drafts, and reopen the last file if there is one.

### Open a file
- Show it, then Refresh that file.
- With no draft, GitHub's newer text simply appears. With one, you see the conflict.
- A file you've never opened needs a connection the first time.

### Open today
- Same as opening a file.
- If today isn't in the cache, show the template with today's date. The refresh swaps in GitHub's copy if the web started the day.
- A new day's first Publish adds it to the Daily notes gist GitHub has, or creates that gist when there's none.

### New gist
- Opens blank, on the phone only. Naming it is a Save, like typing.
- Its first Publish creates the gist on GitHub. If that Publish is cut off, the next one finds the gist it made instead of making another.

### Edit
- Each keystroke is a Save.
- Publish 5 seconds after you stop typing (Autosave, on by default), when you leave the file, and when you leave the app.
- Open something and leave without typing, and nothing is left behind.

### Add to Today
- Open today, add the text as a Save, then Publish.
- It works with the app closed. Offline, it publishes at the next launch.

### Conflict
- GitHub moved past your base while you had a draft. You see both versions.
- Keep Mine: base ← GitHub, then Publish.
- Use GitHub's: draft ← GitHub's text, as an edit you can undo. It now matches GitHub, so the draft is deleted.
- GitHub's side is empty when the file was deleted elsewhere. Keep Mine adds it back.

### Deleted elsewhere
- A gist deleted on the web leaves the list at the next Refresh.
- If you had a draft, it stays on the phone and never publishes, so you can copy your words out. Delete removes it.

### Return to the app
- Publish any drafts.
- Refresh the open file.
- Refresh the list.

### Delete
- A gist: Delete. One that never reached GitHub is only a draft, so it works offline.
- A daily note: Delete that day's file, or the whole gist when it's the last day. A deleted today stays deleted until you open today again.
- Deleting the file you have open leaves nothing open.

### Everything else
- Title, star, archive, comments, adding or renaming a file, tags, pins and settings apply right away. They need a connection and are never drafted.
- A new file starts blank. A renamed file keeps its draft.
- Someone else's gist is read-only.

### Accounts
- Signing out keeps your drafts. They publish when you sign back in.

### Offline
- Save and reading the cache work. Publish and Refresh wait for the next moment above.

### What you see
- Nothing, while it's on GitHub or will publish by itself.
- **Publish**, when Autosave is off or a publish didn't land. Tapping it publishes.
- **GitHub needs attention**, for a conflict or a GitHub reconnect.
- **Couldn't sync** or **Couldn't update your gists**, in the list, when a change didn't go through or the list couldn't refresh. A refresh that only timed out or lost its connection shows nothing, and the next moment tries again.

### Left out on purpose
- No merging, no background sync and no retry timers.

---

*Where the code differs today:* it creates a draft when you open a file, keeps it after publishing and deletes untouched ones later. Adding a file makes a draft instead of creating the file. A new day publishes any earlier unpublished day first. t323 makes the code match this page.
