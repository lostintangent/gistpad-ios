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
deletion, partial targeting and Japanese targeting require byte-exact expected
source. Addition requires exactly one new unchecked task in the correct list,
matching the requested task text case-insensitively. Removing only the inserted
bytes must recover the entire original source exactly.

Favorite answers are graded on generated prose, not cited text or exact sentence
equality. Deterministic checks require the expected work's name, a preference
assertion and no alternative series in a favorite assertion. A separate greedy
on-device meaning grade is recorded as an extra signal, not the primary pass
decision. Ranking-based caveats are allowed. Review all retained favorite answers
alongside the table, including model-grade disagreements. The conservative text
checks are English-specific and can reject comparative explanations. Summary
currently checks nonempty completion only, not summary quality. Neither favorite
grade validates the factual accuracy of the answer's explanation or inline
quotations. Human review must distinguish those from app-verified source citations.

The output contains a per-case pass-rate table and content-free failure categories.
The acceptance floor is 100% for every Edit case and at least 90% for favorite
cases across at least 10 repetitions. Below-floor runs exit unsuccessfully.
Record the runtime model variant and context alongside results. A Mac Core result
is not proof of Advanced-model behavior on the Duo.

The shared evaluator also supports a DEBUG app launch with
`--evaluate-intelligence --intelligence-eval-repeats 10`. Before launching, copy
the generated `cases.json` to the app container's
`Library/Application Support/IntelligenceEval/cases.json`. The app does not sign
in, publish or change any notebook. It writes incremental content-free
`results.json` and `summary.md` beside that input for read-only retrieval.
Device launch requires the user's explicit approval.
