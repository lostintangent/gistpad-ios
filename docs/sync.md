# How sync works

## Nouns

- **GitHub** is the truth. Gists hold files, and files hold text.
- **Cache** is the phone's copy of GitHub: the gist list, plus the text of each file you've opened.
- **Draft** is one file's unpublished text, plus the **base**, which is GitHub's text when you started typing. A new gist or a new day has no base.

## Rules

- You see the draft if there is one, and otherwise the cache.
- A file has at most one draft.
- A draft only exists while GitHub doesn't have its text. Typing creates it, and publishing deletes it.
- Only Publish and Delete write to GitHub.

## Verbs

- **Refresh:** cache ← GitHub.
- **Save:** draft ← your text. The first keystroke creates the draft, with base ← what you were looking at.
- **Publish:** if GitHub is still the base, or already has your text, then GitHub ← draft, cache ← GitHub, and the draft is deleted. Otherwise it's a conflict.
- **Delete:** the gist or file leaves GitHub, the cache and the phone.

## Scenarios

### Launch
- First time: sign in with GitHub, then Refresh.
- After that: show the cache, Refresh, Publish any leftover drafts, and reopen the last file.

### Open a file
- Show it, then Refresh that file.
- With no draft, GitHub's latest text simply appears.

### Open today
- Same as opening a file.
- If today isn't in the cache, show the template with today's date. The refresh swaps in GitHub's copy if the web started the day.

### New gist
- Opens blank, on the phone only.

### Edit
- Each keystroke is a Save.
- Publish 5 seconds after you stop typing, when you leave the file, and when you leave the app.
- A new gist or a new day creates the gist or file on GitHub at its first Publish.
- Open something and leave without typing, and nothing is left behind.

### Conflict
- GitHub moved past your base while you had a draft. You see both versions.
- Keep Mine: base ← GitHub, then Publish.
- Use GitHub's: draft ← GitHub's text, as an edit you can undo. It now matches GitHub, so the draft is deleted.

### Return to the app
- Publish any drafts.
- Refresh the open file.
- Refresh the list if it's more than 5 minutes old or the last refresh failed.

### Delete
- A gist: Delete. One that never reached GitHub is only a draft, so it works offline.
- A daily note: Delete that day's file, or the whole gist when it's the last day.

### Everything else
- Title, star, archive, file rename, tags, pins and settings apply right away. They need a connection and are never drafted.
- Someone else's gist is read-only.

### Offline
- Save and reading the cache work. Publish and Refresh wait for the next moment above.

### What you see
- Nothing, while it's on GitHub or will publish by itself.
- **Publish**, when Autosave is off or a publish didn't land. Tapping it publishes.
- **GitHub needs attention**, for a conflict or a GitHub reconnect.
- **Couldn't sync** or **Couldn't update your gists**, in the list, when a change didn't go through or the list couldn't refresh.

### Left out on purpose
- No merging, no background sync and no retry timers.

---

*Where the code differs today:* it creates a draft when you open a file instead of at the first keystroke. It keeps the draft after publishing and deletes untouched ones later. t323 makes the code match this page.
