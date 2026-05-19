#!/usr/bin/env bash
# Install a built WhisperKey.app into /Applications and register it for launch/search.

set -euo pipefail

APP_PATH="${1:-}"
DESTINATION_DIR="${2:-/Applications}"
EXPECTED_BUNDLE_ID="yung-sun-xxi.WhisperKey"

if [[ -z "$APP_PATH" ]]; then
    echo "Usage: $0 <path-to-WhisperKey.app> [destination-dir]" >&2
    exit 1
fi

APP_PATH="${APP_PATH%/}"
if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
    echo "ERROR: '$APP_PATH' is not an app bundle." >&2
    exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "ERROR: '$APP_PATH' does not contain Contents/Info.plist." >&2
    exit 1
fi

if ! BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null); then
    echo "ERROR: '$APP_PATH' does not declare CFBundleIdentifier." >&2
    exit 1
fi

if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "ERROR: '$APP_PATH' has bundle id '$BUNDLE_ID', expected '$EXPECTED_BUNDLE_ID'." >&2
    exit 1
fi

mkdir -p "$DESTINATION_DIR"

APP_NAME="$(basename "$APP_PATH")"
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME"
TEMP_APP="$DESTINATION_DIR/.$APP_NAME.installing.$$"

if [[ -e "$DESTINATION_APP" && "$APP_PATH" -ef "$DESTINATION_APP" ]]; then
    echo "WhisperKey is already installed at $DESTINATION_APP"
    exit 0
fi

cleanup() {
    rm -rf "$TEMP_APP"
}
trap cleanup EXIT

rm -rf "$TEMP_APP"
ditto --rsrc --extattr "$APP_PATH" "$TEMP_APP"
rm -rf "$DESTINATION_APP"
mv "$TEMP_APP" "$DESTINATION_APP"
trap - EXIT

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DESTINATION_APP" >/dev/null 2>&1 || true
fi

if command -v mdimport >/dev/null 2>&1; then
    mdimport "$DESTINATION_APP" >/dev/null 2>&1 || true
fi

echo "Installed WhisperKey to $DESTINATION_APP"
