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


reading = fixture("reading-list.md")
daily = fixture("daily-log.md")
essay = fixture("strategy-essay.md")
dogfood = fixture("dogfooding-log.md")
home = fixture("home-project.md")
cases = []


def ask(name, source, prompt, mentions=None, avoids=None, favorite=None,
        alternatives=None, words=60, exact_answers=None):
    cases.append(dict(id=name, action="ask", source=source, prompt=prompt,
                      mentions=mentions, avoids=avoids, favorite=favorite,
                      alternativeFavorites=alternatives, maximumAnswerWords=words,
                      exactAnswers=exact_answers))


def exact(name, source, prompt, expected):
    cases.append(dict(id=name, action="edit", source=source, prompt=prompt,
                      expectedSource=expected))


def replacement(source, old, new):
    assert source.count(old) == 1, old
    return source.replace(old, new)


def passage(source, start, end=None):
    first = source.index(start)
    last = source.index(end, first) if end else source.find("\n\n", first)
    if last < 0:
        last = len(source.rstrip("\n"))
    return source[first:last]


# The live note puts currently-reading titles and front matter before the ranked list.
# This synthetic note has the same traps without copying anyone's private reading data.
ask("synthetic-favorite", reading, "what is my favorite series?",
    favorite="The Cedar Compass",
    alternatives=["Harbor Signal", "Glass Loom", "Night Orchard", "A Quiet Harbor",
                  "Lantern Makers", "Orchard Tram", "Cloud Cartographer"])
ask("reading-higher", reading,
    "Which did I rank higher, Night Orchard or Lantern Makers? Name only the higher-ranked one.",
    [["Night Orchard"]], ["Lantern Makers"], exact_answers=["Night Orchard"])
ask("reading-volume", reading, "Which volume of Harbor Signal am I currently reading?",
    [["7", "seven"]])
ask("reading-stopped", reading, "Which volume of Cloud Cartographer did I stop at?",
    [["4", "four"]])
ask("reading-taste", reading, "What kind of stories do I like?",
    [["character", "people", "decisions carry", "choices", "relationships"],
     ["consequence", "stillness", "quiet", "gesture", "ending",
      "conclusion", "art creates space"]])
ask("reading-count", reading, "How many series are in the Exceptional tier?",
    [["four", "4"]])
ask("reading-end", reading, "Which series do I plan to reread in December?",
    [["The Cedar Compass"], ["December"]])
ask("reading-unknown", reading, "What is my purchase budget for next year?",
    [["not ", "no ", "n't", "unspecified"]], ["$"])

# The original daily task operations now run against a real-sized daily note.
cases.append(dict(id="daily-add", action="edit", source=daily,
                  prompt="add an item to clean the kitchen",
                  addedTaskText="clean the kitchen", addedTaskListTitle="Housework"))
done_chapter = replacement(daily, "- [ ] Read a chapter", "- [x] Read a chapter")
chores = replacement(daily, "## Housework", "## Chores")
for name, prompt, expected in [
    ("complete", "mark Read a chapter complete", done_chapter),
    ("all", "mark everything complete", daily.replace("- [ ] ", "- [x] ")),
    ("delete", "delete Take out the recycling",
     replacement(daily, "- [ ] Take out the recycling\n", "")),
    ("partial", "mark the first two tasks done",
     done_chapter.replace("- [ ] Make coffee", "- [x] Make coffee")),
    ("uncheck", "uncheck all tasks", daily.replace("- [x] ", "- [ ] ")),
    ("japanese", "Read a chapter のタスクを完了にしてください", done_chapter),
    ("text", "rename the Housework heading to Chores", chores),
    ("mixed", "mark Read a chapter complete and rename the Housework heading to Chores",
     replacement(done_chapter, "## Housework", "## Chores")),
    ("rename-task", "change Make coffee to Make tea",
     replacement(daily, "Make coffee", "Make tea")),
    ("mixed-add", "add Water the plants to Housework and rename that heading to Home",
     replacement(
         replacement(daily, "## Housework\n\n", "## Home\n\n"),
         "- [ ] Take out the recycling\n",
         "- [ ] Take out the recycling\n- [ ] Water the plants\n")),
]:
    exact(f"daily-{name}", daily, prompt, expected)


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


exact("reading-rename", reading, "rename Started but stopped to Paused reading",
      replacement(reading, "## Started but stopped", "## Paused reading"))
exact("reading-move", reading,
      "move Paper Observatory from Currently reading to Started but stopped",
      replacement(
          replacement(reading, "4. Paper Observatory (2)\n", ""),
          "3. River Engine (6)\n", "3. River Engine (6)\n4. Paper Observatory (2)\n"))
cedar_paragraph = passage(reading, "The Cedar Compass stays first.")
cases.append(dict(
    id="reading-shorter", action="edit", source=reading,
    prompt="shorten the paragraph explaining why The Cedar Compass ranks first",
    editedRegion=rewriting(
        reading, cedar_paragraph, shape="paragraph", language="en",
        shorterThan=len(cedar_paragraph))))
cases.append(dict(
    id="reading-new-section", action="edit", source=reading,
    prompt="add a Favorite cover art section at the end",
    editedRegion=inserting(
        reading, "its current volume as an opinion.", shape="section",
        mustContain=["## Favorite cover art"])))

early_prototypes = passage(essay, "Early prototypes tried")
last_essay = passage(essay, "The first principle is still")
meeting_debate = passage(daily, "Attendees: Priya")
for name, source, prompt, region in [
    ("draft-add-paragraph", essay, "add a paragraph about evidence after the introduction",
     inserting(essay, "excited first minute.", "## What changed",
               shape="paragraph", language="en", mustContain=["evidence"])),
    ("draft-shorter", essay, "shorten the paragraph about early prototypes",
     rewriting(essay, early_prototypes, shape="paragraph", language="en",
               shorterThan=len(early_prototypes))),
    ("draft-grammar", essay, "fix the grammar in the paragraph about early prototypes",
     rewriting(essay, early_prototypes, shape="paragraph", language="en",
               mustNotContain=["patterns was", "team keep"])),
    ("draft-tone", essay, "make the final paragraph more formal",
     rewriting(essay, last_essay, shape="paragraph", language="en")),
    ("meeting-summary", daily, "add a one-sentence summary under the Launch sync heading",
     inserting(daily, "### Launch sync", "Attendees:", shape="paragraph", language="en")),
    ("meeting-list", daily, "turn the launch debate into a list",
     rewriting(daily, meeting_debate, shape="list")),
    ("meeting-translate", daily, "translate the Launch sync paragraph into Spanish",
     rewriting(daily, meeting_debate, language="es",
               mustContain=["Priya", "Marco", "Dana"])),
    ("meeting-section", daily, "add a Risks section at the end",
     inserting(daily, "changes in the morning.", shape="section", mustContain=["## Risks"])),
    ("readme-intro", dogfood, "write a short intro under the title",
     inserting(dogfood, "# Tide CLI dogfooding log", "I keep this note",
               shape="paragraph", language="en")),
    ("readme-section", dogfood, "add an Uninstall section after Install",
     inserting(dogfood, "output on my comparison fixture.", "### Options", shape="section",
               mustContain=["### Uninstall", "brew uninstall tide"])),
    ("readme-table-row", dogfood,
     "add a row to the Options table for a -n flag that numbers each line",
     inserting(dogfood, "| `-i` | Ignore case when comparing |", "\n\n### Usage",
               shape="tableRow", mustContain=["-n"])),
    ("readme-japanese", dogfood, "最後にライセンスについての短い段落を追加してください",
     inserting(dogfood, "Those questions cannot be answered from this log.",
               shape="paragraph", language="ja")),
]:
    cases.append(dict(id=name, action="edit", source=source, prompt=prompt,
                      editedRegion=region))
exact("draft-delete", essay, "delete the paragraph about early prototypes",
      replacement(essay, early_prototypes + "\n\n", ""))
exact("meeting-typo", replacement(daily, "400 testers", "400 tetsers"),
      "fix the typo in the Launch sync paragraph", daily)
exact("home-heading", home, "rename the Entry heading to Hallway",
      replacement(home, "## Entry", "## Hallway"))
exact("home-move", home, "move Paint the window trim from Kitchen to Entry",
      replacement(
          replacement(home, "- [ ] Paint the window trim\n", ""),
          "- [ ] Patch the wall by the coat hooks",
          "- [ ] Paint the window trim\n- [ ] Patch the wall by the coat hooks"))
cases.append(dict(id="home-add-task", action="edit", source=home,
                  prompt="add a task to check the kitchen tap under Kitchen",
                  addedTaskText="check the kitchen tap", addedTaskListTitle="Kitchen"))
cases.append(dict(id="home-cost-row", action="edit", source=home,
                  prompt="add a $75 cabinet-handle row to the cost estimate table",
                  editedRegion=inserting(home, "| Contingency | $300 | Mara | Reserved |",
                                          "\n\nThe seven lines", shape="tableRow",
                                          mustContain=["cabinet", "$75"])))


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
    alternatives = [
        re.sub(r"\s*\([^)]*\)\s*$", "", match.strip())
        for match in re.findall(r"^\s*\d+[.)]\s+(.+)$", source, re.MULTILINE)
        if not match.strip().startswith(args.favorite)
    ]
    for name, question in [
        ("live-manga-favorite", "What is my favorite series"),
        ("live-manga-whats", "what's my favorite series"),
        ("live-manga-like", "which manga do I like most?"),
        ("live-manga-top", "what's my top manga?"),
    ]:
        ask(name, source, question, favorite=args.favorite, alternatives=alternatives)
    ask("live-manga-summary", source, "what's the summary of the manga reading list",
        [["reading", "manga"], ["rank", "finished", "completed"]], words=None)
    padding = (
        "A future update will track availability, editions, binding, language, "
        "publication dates and prices. These are planning details, not a ranking "
        "or completed reading. "
    )
    ask("live-manga-padded",
        source + "\n\n## Future reference\n\n" + padding * 7,
        "What is my favorite series", favorite=args.favorite,
        alternatives=alternatives)
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

# A long text request may fail safely, but task changes must still work at that length.
cases.append(dict(id="long-room", action="edit", source=dogfood,
                  prompt="move the offline-pipe retest to November 9",
                  expectedError="noteTooLong"))
exact("long-all-done", daily, "mark everything done",
      daily.replace("- [ ] ", "- [x] "))

ask("ask-meeting-date", daily, "When is the launch?", [["May 12"]])
ask("ask-meeting-delay", daily, "Who wanted to delay the launch, and why?",
    [["Marco"], ["sign-in", "sign in"]])
ask("ask-meeting-fix", daily, "Which release has the sign-in fix?", [["1.0.1"]])
ask("ask-meeting-open", daily, "What is still left to do for the launch?",
    [["release notes"], ["workaround"]])
ask("ask-meeting-unknown", daily, "What launch budget did we agree on?",
    [["not ", "no ", "n't", "unspecified"]], ["17 million", "$"])
ask("ask-daily-left", daily, "What's left on my Morning and Housework lists?",
    [["coffee"], ["chapter"], ["dishes"], ["recycling"]], words=None)
ask("ask-daily-done", daily, "Which Morning task is done?", [["curtains"]])
ask("ask-daily-end", daily, "When does the library hold expire?",
    [["Friday"], ["6 p.m.", "6pm", "six"]])
ask("ask-daily-summary", daily, "Summarize my Launch sync discussion.",
    [["Marco"], ["Dana"], ["May 12"], ["1.0.1"]], words=None)

ask("ask-readme-install", dogfood, "How do I install Tide?", [["brew install tide"]])
ask("ask-readme-unique", dogfood, "What does -u do?", [["unique"]])
ask("ask-readme-case", dogfood, "Which flag ignores case?", [["-i"]])
ask("ask-dogfood-high", dogfood, "Which High issue remains open?",
    [["T-18", "offline retry"]], ["T-23", "T-25"])
ask("ask-dogfood-count", dogfood, "How many issues are still open?",
    [["three open", "3 open", "three issues", "3 issues",
      "three remain", "3 remain"]])
ask("ask-dogfood-end", dogfood, "When is the next offline-pipe retest?",
    [["November 6"]])
ask("ask-dogfood-summary", dogfood, "Summarize the October 18 issue.",
    [["duplicate"], ["boundary", "chunk"], ["-u"]], words=None)
ask("ask-dogfood-unknown", dogfood, "What is the release date?",
    [["not ", "no ", "n't", "unknown"]])

ask("ask-draft-why", essay, "Why does durability rank first?",
    [["lost", "survive", "safe", "keep"], ["draft", "work", "paragraph"]])
ask("ask-draft-now", essay, "When does the writer trial end?", [["June 18"]])
ask("ask-draft-summary", essay, "Summarize the principles.",
    [["durab", "save"], ["evidence", "review"], ["system", "native"]], words=None)
ask("ask-strategy-higher", essay,
    "Which principle ranks higher, evidence or automation? Name only the higher one.",
    [["evidence"]], ["automation"], exact_answers=["Evidence"])
ask("ask-strategy-native", essay, "Summarize the Third: native habits section.",
    [["platform", "system"], ["selection", "navigation", "control"]], words=None)
ask("ask-strategy-count", essay, "How many ranked principles are there?",
    [["five", "5"]])
ask("ask-strategy-unknown", essay, "What licensing price was set for the experiment?",
    [["not ", "no ", "n't", "unspecified"]], ["$"])

ask("ask-home-total", home, "What is the total cost estimate?",
    [["$2,300", "2300", "2,300"]])
ask("ask-home-higher", home,
    "Which estimate is higher, the sink or plumbing labor? Name only the higher item.",
    [["sink"]], ["plumbing labor"], exact_answers=["Sink", "Sink and fittings"])
ask("ask-home-floor", home, "Who is inspecting the loose floorboard?",
    [["Noor"]], ["You are the one inspecting", "You inspect"])
ask("ask-home-count", home, "How many cost lines are in the estimate?",
    [["seven", "7"]])
ask("ask-home-end", home, "When will the kitchen measurements be sent?",
    [["November 10"]])
ask("ask-home-summary", home, "Summarize the decisions about the door and the rug.",
    [["door"], ["rug"], ["keep", "stays"]], words=None)
ask("ask-home-unknown", home, "What is the quoted cost of a new door?",
    [["not ", "no ", "n't", "unknown"]], ["$"])

# The live question remains separate from the committed synthetic sources.
for note, minimum, maximum in [
    (reading, 1500, 2000),
    (daily, 900, 1200),
    (essay, 1700, 2200),
    (dogfood, 1300, 1700),
    (home, 1050, 1350),
]:
    assert minimum <= len(note.split()) <= maximum
    assert sum(case["action"] == "ask" and case["source"] == note for case in cases) >= 5
    assert sum(case["action"] == "edit" and case["source"] == note for case in cases) >= 4
assert len({case["id"] for case in cases}) == len(cases)
for case in cases:
    if "editedRegion" in case:
        region = case["editedRegion"]
        source = case["source"]
        assert source.startswith(region["prefix"])
        assert source.endswith(region["suffix"])
        assert len(source) >= len(region["prefix"]) + len(region["suffix"]), case["id"]
args.output.mkdir(parents=True, exist_ok=True)
(args.output / "cases.json").write_text(json.dumps(cases, indent=2))
