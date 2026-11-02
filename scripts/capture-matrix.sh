#!/bin/bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${CAPTURE_DEVICE:-9D572007-6DFF-4AE9-8EF8-742F1B5891D1}"
APP="$ROOT/DerivedData/Build/Products/Debug-iphonesimulator/GistPad.app"
NAME=""
POSE="both"
CONTRAST="standard"
OUTPUT=""
POSTURE_HOOK=""
POSTURE_READY=false
SETTLE=6

usage() {
    cat <<'HELP'
Usage: scripts/capture-matrix.sh --name NAME [options] [-- APP ARGUMENTS]

Installs the current build and captures the cover and open displays, in Dark at Large.
Everything after -- goes to the app (default: --fixture standard), for example
  scripts/capture-matrix.sh --name shape-split -- --fixture standard --open shape --mode split

  --app PATH             Built simulator .app (default: DerivedData build)
  --device UDID          Already-booted Duo (default: CAPTURE_DEVICE or shared Duo)
  --name NAME            File name prefix for this capture
  --output PATH          Evidence directory (default: DerivedData/Captures/...)
  --pose both|cover|open  Postures to capture (default: both)
  --contrast standard|increased|both
  --posture-hook PATH    Executable called with DEVICE and cover/open
  --posture-ready        Single pose only: caller has already set posture
  --settle SECONDS       Time to settle after launch (default: 6)
  --help

simctl cannot fold a Duo. Without a hook this command pauses for you to set
the requested posture in Simulator.
HELP
}

fail() {
    printf 'capture-matrix: %s\n' "$*" >&2
    exit 1
}

APP_ARGUMENTS=(--fixture standard)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --posture-ready) POSTURE_READY=true; shift ;;
        --) shift; APP_ARGUMENTS=("$@"); break ;;
        --app|--device|--name|--output|--pose|--contrast|--posture-hook|--settle)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            case "$1" in
                --app) APP="$2" ;;
                --device) DEVICE="$2" ;;
                --name) NAME="$2" ;;
                --output) OUTPUT="$2" ;;
                --pose) POSE="$2" ;;
                --contrast) CONTRAST="$2" ;;
                --posture-hook) POSTURE_HOOK="$2" ;;
                --settle) SETTLE="$2" ;;
            esac
            shift 2
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "--name is required and must be a simple file name"
[[ "$SETTLE" =~ ^[0-9]+$ ]] || fail "--settle must be a nonnegative integer"
case "$POSE" in both) POSES=(cover open) ;; cover|open) POSES=("$POSE") ;; *) fail "Invalid --pose" ;; esac
case "$CONTRAST" in
    standard) CONTRASTS=(disabled) ;;
    increased) CONTRASTS=(enabled) ;;
    both) CONTRASTS=(disabled enabled) ;;
    *) fail "Invalid --contrast" ;;
esac
[ "$POSTURE_READY" = false ] || [ "$POSE" != both ] || fail "--posture-ready requires one --pose"
[ -d "$APP" ] || fail "Build the simulator app first. Not found: $APP"
if [ -n "$POSTURE_HOOK" ]; then
    [[ "$POSTURE_HOOK" = /* ]] && [ -x "$POSTURE_HOOK" ] || fail "--posture-hook must be an absolute executable path"
elif [ "$POSTURE_READY" = false ]; then
    [ -t 0 ] || fail "Posture requires a terminal, --posture-hook, or single-pose --posture-ready"
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
OUTPUT="${OUTPUT:-$ROOT/DerivedData/Captures/$(date -u +%Y%m%dT%H%M%SZ)-$NAME}"
mkdir -p "$OUTPUT"
xcrun simctl bootstatus "$DEVICE"
xcrun simctl io "$DEVICE" enumerate > "$OUTPUT/displays.txt"
grep -q 'Device Name: primary-1' "$OUTPUT/displays.txt" || fail "The selected simulator does not expose both Duo displays"
xcrun simctl install "$DEVICE" "$APP"

# Device types disagree on which framebuffer is the cover, so map by size.
display_width() {
    xcrun simctl io "$DEVICE" screenshot --display="$1" "$OUTPUT/probe-$1.png" >/dev/null 2>&1 \
        || fail "Could not read the $1 display"
    /usr/bin/sips -g pixelWidth "$OUTPUT/probe-$1.png" | awk '/pixelWidth/ { print $2 }'
    rm "$OUTPUT/probe-$1.png"
}
if [ "$(display_width primary)" -gt "$(display_width primary-1)" ]; then
    OPEN_DISPLAY=primary COVER_DISPLAY=primary-1
else
    OPEN_DISPLAY=primary-1 COVER_DISPLAY=primary
fi

OLD_APPEARANCE="$(xcrun simctl ui "$DEVICE" appearance)"
OLD_CONTRAST="$(xcrun simctl ui "$DEVICE" increase_contrast)"
OLD_SIZE="$(xcrun simctl ui "$DEVICE" content_size)"
restore_settings() {
    xcrun simctl ui "$DEVICE" appearance "$OLD_APPEARANCE"
    xcrun simctl ui "$DEVICE" increase_contrast "$OLD_CONTRAST"
    xcrun simctl ui "$DEVICE" content_size "$OLD_SIZE"
}
trap restore_settings EXIT
xcrun simctl ui "$DEVICE" appearance dark
xcrun simctl ui "$DEVICE" content_size large

for pose in "${POSES[@]}"; do
    if [ -n "$POSTURE_HOOK" ]; then
        "$POSTURE_HOOK" "$DEVICE" "$pose"
    elif [ "$POSTURE_READY" = false ]; then
        printf '\nSet the Duo to %s in Simulator, then press Return: ' "$pose"
        read -r
    fi
    if [ "$pose" = cover ]; then display="$COVER_DISPLAY"; else display="$OPEN_DISPLAY"; fi
    for increased in "${CONTRASTS[@]}"; do
        xcrun simctl ui "$DEVICE" increase_contrast "$increased"
        xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID" "${APP_ARGUMENTS[@]}" >/dev/null
        sleep "$SETTLE"
        suffix=""
        [ "$increased" = disabled ] || suffix="-contrast"
        xcrun simctl io "$DEVICE" screenshot --display="$display" "$OUTPUT/$NAME-$pose$suffix.png" >/dev/null
    done
done

printf '\nCaptured %s in %s\n' "$NAME" "$OUTPUT"
