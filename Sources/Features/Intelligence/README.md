# Intelligence

GistPad's own AI: Ask, Edit and Review over the whole note, run by Apple
Intelligence's on-device model through the Foundation Models framework. Nothing
leaves the phone, and nothing in the note changes until you apply it. Siri and
Writing Tools are the system's and work alongside, so this module adds only
what they can't: answers that cite the note, and Markdown-aware edits and
suggestions you review first.

```swift
IntelligenceSheet(editor: editor, title: name) { range in reveal(range) }

let answer = try await OnDeviceModel().ask(request, onPartialAnswer: { partial = $0 })
let proposal = try await OnDeviceModel().review(request)
```

## Nouns

| Type | What it is |
|---|---|
| `IntelligenceAction` | Ask, Edit or Review. |
| `IntelligenceRequest` | What you asked, about the note's `MarkdownDocument`. `Progress` says how far a long one has run. |
| `IntelligenceModel` | The language model the actions run on. `ask`, `edit` and `review` are built on its requirements. |
| `OnDeviceModel` | `SystemLanguageModel` with GistPad's prompts and generation schemas. |
| `ModelPass` | One call to the model, over the note or one part of it. `tokenCount(for:)` counts it exactly as it runs. |
| `IntelligenceError` | Why an action failed, in one sentence. |

### Ask

| Type | What it is |
|---|---|
| `Answer`, `Answer.Citation` | The prose, and each passage it cites at the ranges where the note has it. |
| `Answer.Reply` | The model's prose and quotes before they're checked. `Answer(reply, in:)` finds every quote or throws. |
| `Answer.Issue` | Why a reply's prose can't be shown, such as a quote the note doesn't have or leftover Markdown. |

### Edit

| Type | What it is |
|---|---|
| `EditOperation` | An edit as the model describes it, in task IDs and ranges within its pass. `changes(in:pass:scope:)` turns it into changes to the note. |
| `Proposal`, `Proposal.Change`, `Proposal.Applied` | The changes you review, one change, and the note after applying some. |
| `TextDiff` | The word diff the sheet shows and the unsafe-edit check reads. |

Edit reads the note's blocks, sections, headings, fences and tasks from its
`MarkdownDocument`. `MarkdownDocument+Edit` adds the two readings only Edit
needs: task lists, numbered for the model, and the list item a "move" request
names.

### Review

Review's output is a suggestion. `suggestions(for:)` returns `Proposal.Change`s,
so suggestions are reviewed and applied the same way as an edit. A suggestion
without a replacement is advice, which you dismiss.

### Sheet

| Type | What it is |
|---|---|
| `IntelligenceSheet` | The view App presents over the open note. |
| `IntelligenceState` | The sheet's observable state, holding `any IntelligenceModel`. |

## How an action runs

- Each verb first checks `unavailableReason`, which reads
  `SystemLanguageModel.availability`, and throws its sentence as
  `.unavailable`. The sheet shows the same sentence.
- Front matter is never sent, and a change may only touch the body.
- **Ask** answers from the whole body when it fits the context. Otherwise it
  asks each part for exact excerpts, combines them and answers from those. A
  reply with an `Answer.Issue` or an unverified quote is retried once.
- **Edit** sends the whole body and splits only when the context can't hold
  it. Task requests go through a greedy intent schema, so checking off, adding
  or deleting touches only the tasks it names. Other requests are a rewrite,
  compared line by line.
- **Review** splits the body into parts that fit, and asks each for up to 12
  suggestions anchored to exact quotes.
- A `Proposal` places every change in the note before you see it. Applying is
  one undoable edit made from the proposal's document, so the editor refuses it
  once the note has changed. It also refuses a result that repeats the
  instruction or removes almost everything.

## Testing

`FixtureLanguageModel` scripts the model, so `swift test --filter
IntelligenceTests` never calls Apple Intelligence. The sheet's tests need
UIKit and run in the simulator suite.

Prompts are tuned only against the eval, which runs real notes through the
on-device model on the Mac. See
[scripts/intelligence-eval](../../../scripts/intelligence-eval/README.md).
