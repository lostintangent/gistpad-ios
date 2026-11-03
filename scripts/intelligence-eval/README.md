# Real on-device intelligence evaluations

From the repository root, run `bash scripts/evaluate-intelligence.sh 10`.
The Mac must have Apple Intelligence enabled and the local model available.
This uses `SystemLanguageModel.default`, never a fake backend or cloud service.
Honor the shared `/tmp/gistpad-slot.lock` before running builds or inference.
The evaluation uses the same `Intelligence.ask`, `.edit`, and `.review` paths
as the app. A baseline can exit unsuccessfully when it misses the acceptance
floor; its result files still contain the measured cases.

To include live notes, use:

```sh
bash scripts/evaluate-intelligence.sh 10 \
  --manga-gist MANGA_GIST_ID --favorite EXPECTED_FAVORITE \
  --daily-gist DAILY_GIST_ID --daily-file YYYY-MM-DD.md
```

The runner reads the gists with `gh`, never writes to GitHub and keeps private
inputs and outputs in a freshly created `/tmp/gistpad-intelligence-eval.*`
directory. Do not commit that directory or its `cases.json` or private results.
The optional live Manga set includes the exact phone question and a locally
padded copy whose added reference section does not alter the completed ranking.
Inspect the runtime input-token count and extraction path on each run because
the live note and device context can change. Never commit the live note or its
generated cases.
`prepare.py` combines five committed synthetic Markdown fixtures into the case
file. They approximate full-size personal notes: a 1.7k-word ranked reading
list, a 1k-word daily log, a 1.8k-word essay, a 1.4k-word dogfooding log and
a 1.2k-word home project. They include front matter, multiple task lists,
misleading nearby facts, a table, code, and facts near the end. At least five
Ask and four Edit questions cover each note. Independently prepared held-out
questions must stay outside the repository and must not drive prompt changes.

Each attempt starts from the original bytes. Edit is greedy. Completion,
deletion, partial targeting, Japanese targeting, a heading rename, a task rename,
a request mixing a task completion with that rename and a request adding a task
to "that heading" while renaming it require byte-exact expected source. Addition requires exactly one new unchecked task in the correct list,
matching the requested task text case-insensitively. Removing only the inserted
bytes must recover the entire original source exactly.

General Edit cases run across the five full-size notes. Deleting a paragraph
requires byte-exact expected source. Edits that
write new text are graded on their region instead. Each case pins the exact bytes
before and after the edited region, and both must survive unchanged. The written
text must be nonempty, differ from what it replaced, have the requested shape
(paragraph, list, section or table row) without a code fence, be separated from
its neighbors as Markdown requires and be in the requested language. Some cases
also require or forbid words, or a shorter result. A greedy on-device meaning
grade fills the Meaning column as an extra signal, not the pass decision. It is
lenient and has accepted a shortened paragraph that changed a detail. Keep a
separate held-out set of general cases outside the repository, write it before
measuring and never tune on it.

General Edit on these longer notes selects from an outline with direct-content
previews, then selects one block under that heading. The model rewrites the
section's own content, but only changed hunks entirely within the selected block
are proposed. An oversized section falls back to rewriting that block alone.
An unchanged section does not get a block-only retry: that produced extra
headings and fences outside the requested content in the measured run.
The review is still required: a wrong selection can propose an unrelated change,
and the eval checks every byte outside the requested region. Short notes retain
their existing JSON input and whole-note rewrite; scoped content uses raw
Markdown so model output does not echo JSON-escaped newlines. The `long-room`
case now requires the exact retest-date change instead of accepting `noteTooLong`;
all 35 cases expect an actual edit. Named list-item moves also require their
exact expected insertion position, even when the request names only the
destination heading. Task operations still work without rewriting
the note. If even one selected block cannot fit, report the error rather than
silently truncating the source.

Favorite answers are graded on generated prose, not cited text or exact sentence
equality. Deterministic checks require the expected work's name, a preference
assertion and no alternative series in a favorite assertion. A separate greedy
on-device meaning grade is recorded as an extra signal, not the primary pass
decision. Questions that explicitly ask for only the higher-ranked name require
that name alone. The open-issue count case requires the number attached to
issues, rather than an incidental mention elsewhere in the answer. The
floorboard-inspection case rejects assigning the work to the reader instead of
the named carpenter. Every Ask case rejects unverified quoted spans, leaked
block/field identifiers, third-person references to the reader and unrequested
HTML. Factual cases also have a 60-word cap, excluding app-supplied citations.
Ask streams plain prose; its final source IDs are checked against body-only
blocks before the app adds quotation chips, and an error clears unfinished prose.
Production rejects the same guardable prose failures, plus braces the source
doesn't contain, with one bounded retry before terminal success. A runaway
answer stops at the response limit. The private results retain rejected prose
too. Ranking-based caveats are allowed. Review retained answers alongside the
table, including model-grade disagreements. The conservative text checks are
English-specific and can reject comparative explanations. Summary must finish
with nonempty prose that passes the same quality guards, but its semantic
coverage is not automatically scored. These guards do not establish the accuracy
of every paraphrased claim. Human review must distinguish inference from an
explicit statement and app-verified source citations. Elapsed time includes the
extra favorite grade and is not an app-latency benchmark. First-visible,
completion and preparation times exclude the grader, and the table reports
their p50/p90 plus retry counts and failures.

The output contains a per-case pass-rate table and content-free failure categories.
The acceptance floor is 100% for every Edit case and at least 90% for favorite
cases across at least 10 repetitions. Below-floor runs exit unsuccessfully.
The 24/35 single-pass Edit path is a Build 34 field candidate by product decision,
not a passing evaluation. The user must review every proposed diff before Apply.
Record the runtime model variant and context alongside results. A Mac Core result
is not proof of Advanced-model behavior on the Duo.
