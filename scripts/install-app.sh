#!/usr/bin/env bash
# Install a built WhisperKey.app into /Applications and register it for launch/search.

set -euo pipefail

APP_PATH="${1:-}"
DESTINATION_DIR="${2:-/Applications}"
EXPECTED_BUNDLE_ID_PREFIX="yung-sun-xxi.WhisperKey"

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

# Accept the release id (yung-sun-xxi.WhisperKey) and per-configuration variants
# such as the Debug build's yung-sun-xxi.WhisperKey.dev.
case "$BUNDLE_ID" in
    "$EXPECTED_BUNDLE_ID_PREFIX" | "$EXPECTED_BUNDLE_ID_PREFIX".*) ;;
    *)
        echo "ERROR: '$APP_PATH' has unexpected bundle id '$BUNDLE_ID'." >&2
        exit 1
        ;;
esac

if ! PROCESS_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null); then
    echo "ERROR: '$APP_PATH' does not declare CFBundleExecutable." >&2
    exit 1
fi

USER_PREFS_DOMAIN="$HOME/Library/Preferences/$BUNDLE_ID"

mkdir -p "$DESTINATION_DIR"

APP_NAME="$(basename "$APP_PATH")"
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME"
TEMP_APP="$DESTINATION_DIR/.$APP_NAME.installing.$$"

show_welcome_on_next_launch() {
    local install_id
    install_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"

    defaults write "$USER_PREFS_DOMAIN" WhisperKey.settings.pendingInstallWelcomeID -string "$install_id"
    defaults write "$BUNDLE_ID" WhisperKey.settings.pendingInstallWelcomeID -string "$install_id"
    defaults synchronize "$USER_PREFS_DOMAIN" >/dev/null 2>&1 || true
    defaults synchronize "$BUNDLE_ID" >/dev/null 2>&1 || true
}

terminate_debugservers_for_running_app() {
    local pid
    local ppid
    local parent_name

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue

        ppid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$ppid" ]] || continue

        parent_name="$(ps -p "$ppid" -o comm= 2>/dev/null | awk -F/ '{ print $NF }')"
        if [[ "$parent_name" == "debugserver" ]]; then
            kill -TERM "$ppid" >/dev/null 2>&1 || true
        fi
    done < <(pgrep -x "$PROCESS_NAME" || true)
}

terminate_running_app() {
    terminate_debugservers_for_running_app
    pkill -TERM -x "$PROCESS_NAME" >/dev/null 2>&1 || true

    for _ in {1..30}; do
        if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        terminate_debugservers_for_running_app
        pkill -KILL -x "$PROCESS_NAME" >/dev/null 2>&1 || true

        for _ in {1..20}; do
            if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
    fi

    if pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        echo "ERROR: Could not stop the existing $PROCESS_NAME process." >&2
        exit 1
    fi
}

restart_installed_app() {
    terminate_running_app
    open -n "$DESTINATION_APP"
}

if [[ -e "$DESTINATION_APP" && "$APP_PATH" -ef "$DESTINATION_APP" ]]; then
    echo "WhisperKey is already installed at $DESTINATION_APP"
    show_welcome_on_next_launch
    restart_installed_app
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

show_welcome_on_next_launch
restart_installed_app

echo "Installed WhisperKey to $DESTINATION_APP"
