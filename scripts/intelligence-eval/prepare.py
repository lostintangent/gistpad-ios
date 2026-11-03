import argparse
import json
from pathlib import Path
import subprocess
import re

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
parser.add_argument("--manga-gist")
parser.add_argument("--daily-gist")
parser.add_argument("--daily-file")
parser.add_argument("--favorite")
args = parser.parse_args()
fixtures = Path(__file__).parent / "Fixtures"


def fixture(name):
    return (fixtures / name).read_text()


daily = fixture("daily.md")
cases = [
    dict(
        id="synthetic-favorite",
        action="ask",
        source=fixture("manga.md"),
        prompt="what is my favorite series?",
        favorite="The Glass Orchard",
        maximumAnswerWords=60,
        alternativeFavorites=["Mountain Trails", "The Clockmaker", "City of Paper",
                              "Winter Lantern", "Summer Postcards", "The Second Train",
                              "Midnight Elevator"],
    ),
    dict(
        id="daily-add",
        action="edit",
        source=daily,
        prompt="add an item to clean the kitchen",
        addedTaskText="clean the kitchen",
        addedTaskListTitle="Housework",
    ),
]
for name, prompt, expected in [
    ("complete", "mark Read a chapter complete", "daily-complete.md"),
    ("all", "mark everything complete", "daily-all.md"),
    ("delete", "delete Take out the recycling", "daily-delete.md"),
    ("partial", "mark the first two tasks done", "daily-partial.md"),
    ("uncheck", "uncheck all tasks", "daily-uncheck.md"),
    ("japanese", "Read a chapter のタスクを完了にしてください", "daily-complete.md"),
    ("text", "rename the Housework heading to Chores", "daily-text.md"),
    ("mixed", "mark Read a chapter complete and rename the Housework heading to Chores",
     "daily-mixed.md"),
    ("rename-task", "change Make coffee to Make tea", "daily-rename-task.md"),
    ("mixed-add", "add Water the plants to Housework and rename that heading to Home",
     "daily-mixed-add.md"),
]:
    cases.append(
        dict(
            id=f"daily-{name}",
            action="edit",
            source=daily,
            prompt=prompt,
            expectedSource=fixture(expected),
        )
    )


def unique(source, text):
    assert source.count(text) == 1, text
    return source.index(text)


def rewriting(source, passage, **checks):
    start = unique(source, passage)
    return dict(prefix=source[:start], suffix=source[start + len(passage):], **checks)


def inserting(source, after, before=None, **checks):
    end = unique(source, after) + len(after)
    suffix = source[unique(source, before):] if before else source[len(source.rstrip("\n")):]
    return dict(prefix=source[:end], suffix=suffix, **checks)


draft = fixture("draft.md")
meeting = fixture("meeting.md")
readme = fixture("readme.md")
first_loaves = ("The first loaves were dense and flat. I followed recipes exactly, but I "
                "didn't understand why each step mattered, so every mistake felt random.")
notebook = next(p for p in draft.split("\n\n") if p.startswith("Things changed"))
saturday = next(p for p in draft.split("\n\n") if p.startswith("Now I bake")).rstrip("\n")
debate = next(p for p in meeting.split("\n\n") if p.startswith("Marco wants"))
next_steps = meeting[unique(meeting, "## Next steps"):].rstrip("\n")
for name, source, prompt, region in [
    ("draft-add-paragraph", draft, "add a paragraph about choosing flour after the intro",
     inserting(draft, "a weekly habit.", "The first loaves", shape="paragraph",
               language="en", mustContain=["flour"])),
    ("draft-shorter", draft, "rewrite the paragraph about the first loaves to be shorter",
     rewriting(draft, first_loaves, shape="paragraph", language="en",
               shorterThan=len(first_loaves))),
    ("draft-grammar", draft, "fix the grammar",
     rewriting(draft, notebook, shape="paragraph", language="en",
               mustNotContain=["patterns was", "loafs", "they was"])),
    ("draft-tone", draft, "make the last paragraph sound more formal",
     rewriting(draft, saturday, shape="paragraph", language="en")),
    ("meeting-summary", meeting, "add a one-sentence summary under the title",
     inserting(meeting, "# Launch sync", "Attendees:", shape="paragraph", language="en")),
    ("meeting-list", meeting, "turn the paragraph about delaying the launch into a list",
     rewriting(meeting, debate, shape="list")),
    ("meeting-translate", meeting, "translate the Next steps section into Spanish",
     rewriting(meeting, next_steps, language="es",
               mustContain=["- [ ] ", "- [x] ", "Priya", "Marco", "Dana"])),
    ("meeting-section", meeting, "add a Risks section at the end",
     inserting(meeting, "launch review", shape="section", mustContain=["## Risks"])),
    ("readme-intro", readme, "write an intro",
     inserting(readme, "# tidy", "## Install", shape="paragraph", language="en")),
    ("readme-section", readme, "add a section about uninstalling after Install",
     inserting(readme, "brew install tidy\n```", "## Options", shape="section",
               mustContain=["## ", "uninstall"])),
    ("readme-table-row", readme, 
     "add a row to the end of the table for a -n option that numbers each line",
     inserting(readme, "| Ignore case when comparing |", "\n\n## Usage", shape="tableRow",
               mustContain=["-n"])),
    ("readme-japanese", readme, "最後にライセンスについての短い段落を追加してください",
     inserting(readme, "standard input instead.", shape="paragraph", language="ja")),
]:
    cases.append(dict(id=name, action="edit", source=source, prompt=prompt,
                      editedRegion=region))
cases.append(dict(id="draft-delete", action="edit", source=draft,
                  prompt="delete the paragraph about the first loaves",
                  expectedSource=fixture("draft-delete.md")))
# One typo in a long, otherwise clean paragraph, which a block rewrite must not drift around.
cases.append(dict(id="meeting-typo", action="edit",
                  source=meeting.replace("400 testers", "400 tetsers"),
                  prompt="fix the typo", expectedSource=meeting))


def gist(gist_id):
    result = subprocess.run(
        ["gh", "api", f"gists/{gist_id}"],
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(result.stdout)
    if any(file.get("truncated") for file in value["files"].values()):
        raise RuntimeError("Eval requires complete, non-truncated gist files")
    return value["files"]


if args.manga_gist:
    if not args.favorite:
        parser.error("--favorite is required with --manga-gist")
    files = gist(args.manga_gist)
    source = files["README.md"]["content"]
    cases += [
        dict(
            id="live-manga-favorite",
            action="ask",
            source=source,
            prompt="what is my favorite series?",
            favorite=args.favorite,
            maximumAnswerWords=60,
            alternativeFavorites=[
                re.sub(r"\s*\([^)]*\)\s*$", "", match.strip())
                for match in re.findall(r"^\s*\d+[.)]\s+(.+)$", source, re.MULTILINE)
                if not match.strip().startswith(args.favorite)
            ],
        ),
        dict(
            id="live-manga-summary",
            action="ask",
            source=source,
            prompt="what's the summary of the manga reading list",
        ),
    ]
if args.daily_gist:
    if not args.daily_file:
        parser.error("--daily-file is required with --daily-gist")
    files = gist(args.daily_gist)
    cases.append(
        dict(
            id="live-daily-add",
            action="edit",
            source=files[args.daily_file]["content"],
            prompt="add an item to clean the kitchen",
            addedTaskText="clean the kitchen",
        )
    )

# General Ask: one fact or list per question, each fact matched by any of its phrasings.
meeting = fixture("meeting.md")
readme = fixture("readme.md")
draft = fixture("draft.md")
people = ["Priya", "Marco", "Dana", "Sam", "Lee", "Ana"]
areas = ["the onboarding flow", "the settings screen", "search", "the widget", "sync errors",
         "the share sheet", "offline mode", "the empty state"]
weeks = []
for week in range(80):
    first, second = people[week % 6], people[(week + 2) % 6]
    area = areas[week % 8]
    entry = (f"## Week {week + 1}\n\nWe reviewed {area}. {first} shared progress and {second} "
             f"raised two questions about scope. We agreed to look at {area} again next week "
             f"once the numbers are in.\n\n- [x] {first} updates the tracker\n"
             f"- [ ] {second} follows up on {area}\n")
    if week == 52:
        entry += "\nThe team offsite will be in the Harbor Room on June 3.\n"
    weeks.append(entry)
long_notes = "# Team notes\n\n" + "\n".join(weeks)
# A note longer than one rewrite: a text edit asks for a selection, and a task edit still works.
cases.append(dict(id="long-room", action="edit", source=long_notes,
                  prompt="move the team offsite to the Lighthouse Room",
                  expectedError="noteTooLong"))
cases.append(dict(id="long-all-done", action="edit", source=long_notes,
                  prompt="mark everything done",
                  expectedSource=long_notes.replace("- [ ] ", "- [x] ")))
for name, source, prompt, mentions, avoids, words in [
    ("meeting-date", meeting, "when is the launch?", [["May 12"]], None, 60),
    ("meeting-delay", meeting, "who wanted to delay the launch, and why?",
     [["Marco"], ["sign-in", "sign in"]], None, 60),
    ("meeting-fix", meeting, "which release has the sign-in fix?", [["1.0.1"]], None, 60),
    ("meeting-open", meeting, "what's still left to do?",
     [["release notes"], ["workaround"]], None, 60),
    ("meeting-unknown", meeting, "what's the launch budget?",
     [["n't", "not ", "no "]], ["$", "dollar"], 60),
    ("readme-install", readme, "how do I install tidy?", [["brew install tidy"]], None, 60),
    ("readme-unique", readme, "what does -u do?", [["unique"]], None, 60),
    ("readme-case", readme, "which flag ignores case?", [["-i"]], None, 60),
    ("draft-why", draft, "why did I start baking?", [["quiet"]], None, 60),
    ("draft-now", draft, "how often do I bake now?", [["Saturday"]], None, 60),
    ("draft-summary", draft, "summarize this note",
     [["bread", "bak"], ["notebook", "notes", "recorded", "wrote down"]], None, None),
    ("daily-left", daily, "what's left on my list today?",
     [["coffee"], ["chapter"], ["dishes"], ["recycling"]], None, None),
    ("daily-done", daily, "what have I finished?", [["curtains"]], None, 60),
    ("long-offsite", long_notes, "where is the team offsite?", [["Harbor Room"]], None, 60),
]:
    cases.append(dict(id=f"ask-{name}", action="ask", source=source, prompt=prompt,
                      mentions=mentions, avoids=avoids, maximumAnswerWords=words))
args.output.mkdir(parents=True, exist_ok=True)
(args.output / "cases.json").write_text(json.dumps(cases, indent=2))
