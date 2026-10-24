#!/usr/bin/env python3
"""Measure fresh simulator app processes. Run only while owning the native slot."""
import json
import os
import pathlib
import statistics
import subprocess
import sys
import time
import uuid

simulator = "D121BF28-CFCF-4020-802D-2C81D38F12E2"
environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
output = pathlib.Path(sys.argv[1])
owner = pathlib.Path("/tmp/gistpad-slot.lock/owner").read_text()
if not owner.startswith("renderer-b1a23830"):
    raise SystemExit("Renderer must own the shared native slot.")

def simctl(*arguments):
    return subprocess.run(["xcrun", "simctl", *arguments], env=environment,
        text=True, capture_output=True, check=True).stdout.strip()

container = pathlib.Path(simctl("get_app_container", simulator, "dev.gistpad.GistPad", "data"))
rows = []
for run in range(1, 6):
    for mode in (["rich", "preview"] if run % 2 else ["preview", "rich"]):
        token = str(uuid.uuid4()).upper()
        ready = container / "Library/Application Support/DocumintSpike" / f"ready-{token}.json"
        started = time.monotonic()
        simctl("launch", "--terminate-running-process", simulator, "dev.gistpad.GistPad",
            "--capture-screen", "documint", "--documint-mode", mode, "--documint-ready-token", token)
        while not ready.exists():
            if time.monotonic() - started > 25:
                raise SystemExit(f"Timed out waiting for cold {mode} readiness.")
            time.sleep(0.025)
        payload = json.loads(ready.read_text())
        if payload["token"] != token or payload["mode"].lower() != mode:
            raise SystemExit("The native readiness record does not match this launch.")
        rows.append({"run": run, "mode": mode, "launchToRenderedMS": (time.monotonic() - started) * 1000,
            "hostToRenderedMS": payload["hostToRenderedMS"]})
result = {"definition": "fresh app process to renderer completion, including simctl launch overhead",
    "rows": rows, "medianLaunchMS": {mode: statistics.median(
        row["launchToRenderedMS"] for row in rows if row["mode"] == mode) for mode in ["rich", "preview"]}}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
