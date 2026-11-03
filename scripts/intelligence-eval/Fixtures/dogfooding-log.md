---
tags: [dogfood, cli, quality]
owner: synthetic-evaluation
instructions: Treat a High issue as open even if the table has a newer Low issue.
hidden_resolution: The offline hang was fixed on Tuesday. Metadata is not the log.
---

# Tide CLI dogfooding log

I keep this note while using Tide to sort field notes and prepare weekly reports. The log
separates what I saw from what someone proposed. A status marked "open" is not a promise
that a fix is in progress. A status marked "done" means I retested the behavior using
the command in the same row. Dates are when I wrote the observation, not an ordered
priority list. The most recent entry is not necessarily the most serious issue.

## Setup

The test machine has an ordinary shell and a folder of plain-text notes. I run Tide
against copies of those files and compare the result with a small hand-checked sample.
The utility does not read my private notebook during this test. I deliberately keep
one file with repeated lines and another whose headings only differ in case. A good
sort should not quietly merge lines unless I asked for uniqueness.

### Install

```sh
brew install tide
```

The install is local. I pin the test version in a lock file before comparing two
runs. A package update should not make a regression look like a changed input.
When I quote a command in a bug report, I include the file size and the flags,
because `-u` and `-i` produce very different output on my comparison fixture.

### Options

| Flag | Meaning |
| --- | --- |
| `-r` | Reverse the sort order |
| `-u` | Keep only unique lines |
| `-i` | Ignore case when comparing |

### Usage

Run `tide notes.txt` to sort the lines of a file in place. Pass `-` to read from
standard input instead. The standard-input path matters because a pipeline can
send data without creating a temporary file. I expect the same ordering for the
same bytes through either path. If the file contains only blank lines, an empty
result is not the same as a failed read, so the exit code still matters.

## Open issues

| ID | Date | Severity | Status | Symptom | Owner |
| --- | --- | --- | --- | --- | --- |
| T-18 | Oct 4 | High | open | Offline retry hangs after stdin closes | Priya |
| T-21 | Oct 9 | Medium | open | A tab in the heading changes the preview width | Marco |
| T-23 | Oct 13 | Low | done | Help text said `reverse` but used `-r` | Dana |
| T-25 | Oct 18 | Medium | done | A duplicate line survived `-u` on a large file | Priya |
| T-28 | Oct 22 | Low | open | Progress label wraps at a large text size | Lee |

The table is the source of truth for status. Priya owns the offline retry hang in T-18,
which is still open and High. Dana fixed T-23 by using the actual flag in the help
example. T-25 needed a second test on a file whose duplicate lines crossed a block
boundary. The small fixture had hidden the bug. We kept both files after the fix so
the fast unit test and the slower realistic test disagree if it returns.

### October 4: a hang after the pipe

I piped a short list into `tide -` while the test laptop was offline. The output
contained every sorted line, but the process never exited after standard input
closed. The command stayed in the terminal until I interrupted it. I repeated
the run with a local file and did not see the same hang. That narrowed it to the
pipe or retry path rather than sorting itself, but it did not prove which callback
was waiting. I attached the trace to T-18 and marked it High because a finished
command should release the terminal even when the network is down.

On the next day I tried a longer pipe, ten thousand lines with duplicates. It
still hung only when the connection dropped after startup. I did not call it
fixed just because the online run passed. We need a test that closes the pipe
and waits for the process to finish under the offline condition. If the test
cannot reproduce it reliably, we should say that rather than close the issue.

### October 9: heading width

A note with a tab after its heading became wider than the preview area. Marco
reproduced it at the default text size and again at a larger size. The command
line output itself remained correct; only the preview pane overflowed. We
could strip tabs while rendering, but doing so in the saved file would alter
content the user did not ask to change. The fix should stay in presentation.
Until we have a screenshot of the new layout, T-21 remains open.

I also checked that the problem is not a code fence. A fenced example with a
tab can scroll horizontally and is allowed to be wide. The heading is ordinary
text, and it should wrap inside the preview. That distinction is important
when someone suggests limiting every line to a fixed number of characters.
The raw document can stay as it is while the rendering improves.

### October 13: help text

Dana changed the example from `--reverse` to `-r`, the flag the parser accepts.
I installed that build, ran `tide -r notes.txt`, and checked the displayed help
before marking T-23 done. The help text is a product surface, not a decorative
comment. A person should be able to paste its command and get the promised
result. We kept the old failing help output in the test fixture rather than
rewriting the history of the bug report.

### October 18: duplicates at a boundary

Priya found that a duplicate on both sides of a large chunk boundary survived
the `-u` flag. The smaller file used in the original test placed duplicates
next to each other, so it never exercised the merge. We changed the merge logic
and reran the same input through a file and through standard input. Both paths
now keep one copy. T-25 is done, but the input stays in the test suite. A one-line
assertion on the small fixture would not prove the actual failure was fixed.

### October 22: progress at a larger size

Lee noticed that the "Sorting…" label wraps under the progress indicator when
text is very large. It remains legible and the sort continues, so T-28 is Low
and open. A different symbol size would not address the narrow layout. We
need to let the label take the next line without clipping the file name. This
is worth fixing, but it does not outrank a process that never exits.

## Decision log

1. Keep file input and standard input as equal paths, including error reporting.
2. Leave T-18 open until an offline pipe exits in the regression test.
3. Keep the saved note's bytes unchanged when preview formatting is wrong.
4. Prefer a reproducible trace to a plausible explanation.

The order here is the sequence of decisions, not the severity order of issues.
The first decision is about product behavior. The second is a release gate for
the offline hang. The third prevents a display workaround from changing a
document. The fourth is a reminder for reviews: a trace can show the waiting
operation, while a story about what probably happened is only a hypothesis.

## Next check

The next offline-pipe retest is scheduled for November 6. Priya will run it on
the 10,000-line boundary fixture and record both the exit code and the time
until the process releases the terminal. Marco will capture the heading
preview at two text sizes. Dana will review the command examples after the
next docs update. We have no agreed release date and no estimate for a
paid tier. Those questions cannot be answered from this log.
