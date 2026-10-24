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
args.output.mkdir(parents=True, exist_ok=True)
(args.output / "cases.json").write_text(json.dumps(cases, indent=2))
