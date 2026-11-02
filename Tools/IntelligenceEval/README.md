# Real on-device intelligence evaluations

From the repository root, run `bash scripts/evaluate-intelligence.sh 10`.
The Mac must have Apple Intelligence enabled and the local model available.
This uses `SystemLanguageModel.default`, never a fake backend or cloud service.
Honor the shared `/tmp/gistpad-slot.lock` before running builds or inference.

To include live notes, use:

```sh
bash scripts/evaluate-intelligence.sh 10 \
  --manga-gist MANGA_GIST_ID --favorite EXPECTED_FAVORITE \
  --daily-gist DAILY_GIST_ID --daily-file YYYY-MM-DD.md
```

The runner reads the gists with `gh`, never writes to GitHub and keeps private
inputs and outputs in a freshly created `/tmp/gistpad-intelligence-eval.*`
directory. Do not commit that directory or its `cases.json` or private results.
Committed fixtures are synthetic, including front matter and multiple task lists.

Each attempt starts from the original bytes. Edit is greedy. Completion,
deletion, partial targeting, Japanese targeting, a heading rename, a task rename,
a request mixing a task completion with that rename and a request adding a task
to "that heading" while renaming it require byte-exact expected source. Addition requires exactly one new unchecked task in the correct list,
matching the requested task text case-insensitively. Removing only the inserted
bytes must recover the entire original source exactly.

General Edit cases run on a prose draft, meeting notes and a README with code and
a table. Deleting a paragraph requires byte-exact expected source. Edits that
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

A note longer than one rewrite runs two cases. Moving its offsite to another room
must end in the `noteTooLong` error, named by the case's `expectedError`, and
marking every task done must still return byte-exact expected source.

Favorite answers are graded on generated prose, not cited text or exact sentence
equality. Deterministic checks require the expected work's name, a preference
assertion and no alternative series in a favorite assertion. A separate greedy
on-device meaning grade is recorded as an extra signal, not the primary pass
decision. Every Ask case rejects unverified quoted spans, leaked block/field
identifiers, third-person references to the reader and unrequested HTML. Factual
cases also have a 60-word cap, excluding app-supplied citations. Production rejects
the same guardable prose failures, plus braces the source doesn't contain, with one
bounded retry before terminal success. A runaway answer stops at the response limit.
The private results retain rejected prose too. Ranking-based caveats are allowed. Review retained answers
alongside the table, including model-grade disagreements. The conservative text
checks are English-specific and can reject comparative explanations. Summary must
finish with nonempty prose that passes the same quality guards, but its semantic
coverage is not automatically scored. These guards do not establish the accuracy
of every paraphrased claim. Human review must distinguish inference from an
explicit statement and app-verified source citations. Elapsed time includes the
extra favorite grade and is not an app-latency benchmark. Answer completion and
preparation times exclude the grader, and the table reports their p50/p90 plus
retry counts and failures.

The output contains a per-case pass-rate table and content-free failure categories.
The acceptance floor is 100% for every Edit case and at least 90% for favorite
cases across at least 10 repetitions. Below-floor runs exit unsuccessfully.
Record the runtime model variant and context alongside results. A Mac Core result
is not proof of Advanced-model behavior on the Duo.
