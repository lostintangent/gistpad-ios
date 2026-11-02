#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${CAPTURE_DEVICE:-9D572007-6DFF-4AE9-8EF8-742F1B5891D1}"
APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app"
SCREEN=""
STATE="populated"
POSE="both"
CONTRAST="standard"
APPEARANCE="both"
ACCENT=""
OUTPUT=""
POSTURE_HOOK=""
POSTURE_READY=false
READING_FIXTURE=false
SETTLE=10

usage() {
    cat <<'HELP'
Usage: scripts/capture-matrix.sh --screen NAME [options]

Installs the current build and captures cover/open x light/dark x Large/AX3.
Use --pose and --appearance to capture a subset.
The app receives --capture-screen NAME --capture-state STATE.
Use only synthetic capture fixtures, never an active account or document.

  --app PATH             Built simulator .app (default: DerivedData build)
  --device UDID          Already-booted Duo (default: CAPTURE_DEVICE or shared Duo)
  --screen NAME          App capture route, such as library, note, or editor
  --state NAME           Synthetic fixture state (default: populated)
  --capture-reading-fixture  Focused Markdown reading fixture (note route only)
  --output PATH          Evidence directory (default: DerivedData/Captures/...)
  --pose both|cover|open  Presentations to capture (default: both)
  --contrast standard|increased|both
  --appearance light|dark|both  Appearances to capture (default: both)
  --capture-accent HEX   Saved accent passed to the app, such as '#FACC15'
  --posture-hook PATH    Executable called with DEVICE and cover/open
  --posture-ready        Single pose only: caller has already set posture
  --settle SECONDS       Render settling time after launch (default: 10)
  --help

simctl cannot fold a Duo. Without a hook this command pauses for you to set
the requested posture in Simulator. It never substitutes a resized window
or an inactive display for actual posture evidence.
HELP
}

fail() {
    printf 'capture-matrix: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --posture-ready) POSTURE_READY=true; shift ;;
        --capture-reading-fixture) READING_FIXTURE=true; shift ;;
        --app|--device|--screen|--state|--output|--pose|--contrast|--appearance|--capture-accent|--posture-hook|--settle)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --app) APP="$2" ;;
                --device) DEVICE="$2" ;;
                --screen) SCREEN="$2" ;;
                --state) STATE="$2" ;;
                --output) OUTPUT="$2" ;;
                --pose) POSE="$2" ;;
                --contrast) CONTRAST="$2" ;;
                --appearance) APPEARANCE="$2" ;;
                --capture-accent) ACCENT="$2" ;;
                --posture-hook) POSTURE_HOOK="$2" ;;
                --settle) SETTLE="$2" ;;
            esac
            shift 2
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ "$SCREEN" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "--screen is required and must be a route name"
[[ "$STATE" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Invalid --state"
[ "$READING_FIXTURE" = false ] || [ "$SCREEN" = note ] || fail "--capture-reading-fixture requires --screen note"
[[ "$SETTLE" =~ ^[0-9]+$ ]] || fail "--settle must be a nonnegative integer"
case "$POSE" in both) POSES=(cover open) ;; cover|open) POSES=("$POSE") ;; *) fail "Invalid --pose" ;; esac
case "$CONTRAST" in
    standard) CONTRASTS=(disabled) ;;
    increased) CONTRASTS=(enabled) ;;
    both) CONTRASTS=(disabled enabled) ;;
    *) fail "Invalid --contrast" ;;
esac
case "$APPEARANCE" in both) APPEARANCES=(light dark) ;; light|dark) APPEARANCES=("$APPEARANCE") ;; *) fail "Invalid --appearance" ;; esac
[ -z "$ACCENT" ] || [[ "$ACCENT" =~ ^#[0-9A-Fa-f]{6}$ ]] || fail "--capture-accent must be a #RRGGBB color"
[ "$POSTURE_READY" = false ] || [ "$POSE" != both ] || fail "--posture-ready requires one --pose"
[ -d "$APP" ] || fail "Build the simulator app first. Not found: $APP"
if [ -n "$POSTURE_HOOK" ]; then
    [[ "$POSTURE_HOOK" = /* ]] && [ -x "$POSTURE_HOOK" ] || fail "--posture-hook must be an absolute executable path"
elif [ "$POSTURE_READY" = false ]; then
    [ -t 0 ] || fail "Posture requires a terminal, --posture-hook, or single-pose --posture-ready"
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
OUTPUT="${OUTPUT:-$ROOT/DerivedData/Captures/$(date -u +%Y%m%dT%H%M%SZ)-$SCREEN-$STATE}"
[ ! -e "$OUTPUT" ] || fail "Output already exists. Choose a new directory: $OUTPUT"
mkdir -p "$OUTPUT"
xcrun simctl bootstatus "$DEVICE"
xcrun simctl io "$DEVICE" enumerate > "$OUTPUT/displays.txt"
grep -q 'Device Name: primary-1' "$OUTPUT/displays.txt" || fail "The selected simulator does not expose both Duo displays"
xcrun simctl install "$DEVICE" "$APP"

OLD_APPEARANCE="$(xcrun simctl ui "$DEVICE" appearance)"
OLD_CONTRAST="$(xcrun simctl ui "$DEVICE" increase_contrast)"
OLD_SIZE="$(xcrun simctl ui "$DEVICE" content_size)"

restore_settings() {
    local failed=0
    xcrun simctl ui "$DEVICE" appearance "$OLD_APPEARANCE" || failed=1
    xcrun simctl ui "$DEVICE" increase_contrast "$OLD_CONTRAST" || failed=1
    xcrun simctl ui "$DEVICE" content_size "$OLD_SIZE" || failed=1
    if [ "$failed" -ne 0 ]; then
        printf 'capture-matrix: Could not restore all simulator settings. See settings-before.txt.\n' >&2
        return 1
    fi
}
trap restore_settings EXIT

printf 'appearance=%s\nincrease_contrast=%s\ncontent_size=%s\n' \
    "$OLD_APPEARANCE" "$OLD_CONTRAST" "$OLD_SIZE" > "$OUTPUT/settings-before.txt"
{
    printf 'captured_at=%s\ndevice=%s\nbundle_id=%s\nscreen=%s\nstate=%s\napp=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEVICE" "$BUNDLE_ID" "$SCREEN" "$STATE" "$APP"
    printf 'app_executable_sha256='
    shasum -a 256 "$APP/$("/usr/libexec/PlistBuddy" -c 'Print CFBundleExecutable' "$APP/Info.plist")"
    printf 'reading_fixture=%s\n' "$READING_FIXTURE"
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$ROOT" --no-pager log -1 --format='revision=%H'
        git -C "$ROOT" --no-pager status --short
    else
        printf 'revision=frozen-source-copy\n'
    fi
    xcodebuild -version
    xcrun simctl list devices available
    xcrun simctl list runtimes
} > "$OUTPUT/build.txt"
printf 'file\tpose\tdisplay\tappearance\tcontrast\tcontent_size\tscreen\tstate\n' > "$OUTPUT/matrix.tsv"

for pose in "${POSES[@]}"; do
    if [ -n "$POSTURE_HOOK" ]; then
        "$POSTURE_HOOK" "$DEVICE" "$pose"
    elif [ "$POSTURE_READY" = false ]; then
        printf '\nSet the Duo to %s in Simulator, then press Return: ' "$pose"
        read -r
    fi
    xcrun simctl io "$DEVICE" enumerate > "$OUTPUT/displays-$pose.txt"
    printf '\nCurrent %s display descriptors:\n' "$pose"
    awk '
        /^    \([0-9]+\) / { integrated = $0 ~ /LCD/ }
        /^Port:/ { integrated = 0 }
        integrated { print }
    ' "$OUTPUT/displays-$pose.txt"
    if [ "$pose" = cover ]; then display=primary; else display=primary-1; fi
    for increased in "${CONTRASTS[@]}"; do
        xcrun simctl ui "$DEVICE" increase_contrast "$increased"
        for appearance in "${APPEARANCES[@]}"; do
            xcrun simctl ui "$DEVICE" appearance "$appearance"
            for size in large accessibility-extra-large; do
                xcrun simctl ui "$DEVICE" content_size "$size"
                token="$(uuidgen)"
                launch_arguments=(--capture-screen "$SCREEN" --capture-state "$STATE" --capture-ready-token "$token")
                if [ "$READING_FIXTURE" = true ]; then
                    launch_arguments+=(--capture-reading-fixture)
                fi
                if [ -n "$ACCENT" ]; then
                    launch_arguments+=(--capture-accent "$ACCENT")
                fi
                xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID" \
                    "${launch_arguments[@]}"
                filename="$SCREEN-$STATE-$pose-$appearance-contrast-$increased-$size.png"
                if [ "$SCREEN" = library ] || [ "$SCREEN" = note ] || [ "$SCREEN" = photos ] || [ "$SCREEN" = scroll-edges ]; then
                    container="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
                    marker="$container/tmp/gistpad-capture-$token.ready"
                    deadline=$((SECONDS + 45))
                    while [ ! -f "$marker" ]; do
                        [ "$SECONDS" -lt "$deadline" ] || fail "The $SCREEN route did not report ready within 45 seconds. No screenshot was saved."
                        sleep 1
                    done
                    cp "$marker" "$OUTPUT/${filename%.png}-ready.json"
                    rm "$marker"
                fi
                sleep "$SETTLE"
                xcrun simctl io "$DEVICE" screenshot --display="$display" "$OUTPUT/$filename"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$filename" "$pose" "$display" "$appearance" "$increased" "$size" "$SCREEN" "$STATE" \
                    >> "$OUTPUT/matrix.tsv"
            done
        done
    done
done

printf '\nCaptured %s states in %s\n' "$((${#POSES[@]} * ${#CONTRASTS[@]} * 4))" "$OUTPUT"
printf 'Review the images for the correct active display, route, fixture and keyboard before submitting.\n'
