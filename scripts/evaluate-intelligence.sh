#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
repeats="${1:-10}"
if (( $# > 0 )); then shift; fi
output="$(mktemp -d /tmp/gistpad-intelligence-eval.XXXXXX)"
python3 "$root/scripts/intelligence-eval/prepare.py" "$output" "$@"
printf 'Private inputs and output: %s\n' "$output"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift run --package-path "$root" -j 2 \
  IntelligenceEval "$output/cases.json" "$output" "$repeats"
