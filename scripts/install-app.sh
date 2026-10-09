#!/usr/bin/env bash
# Install a built WhisperKey.app into /Applications and register it for launch/search.

set -euo pipefail

APP_PATH="${1:-}"
DESTINATION_DIR="${2:-/Applications}"
EXPECTED_BUNDLE_ID_PREFIX="yung-sun-xxi.WhisperKey"
EXPECTED_DEV_TEAM_ID="UGLRY9ACZ6"
RESTART_AFTER_INSTALL="${WHISPERKEY_INSTALL_RESTART:-1}"
STOP_RUNNING_APP="${WHISPERKEY_INSTALL_STOP_RUNNING_APP:-0}"

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

verify_signature() {
    local signing_info
    local designated_requirement
    local authority
    local team_identifier

    if ! /usr/bin/codesign --verify --strict "$APP_PATH" >/dev/null 2>&1; then
        echo "ERROR: '$APP_PATH' does not have a valid code signature." >&2
        exit 1
    fi

    signing_info=$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1)
    if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        echo "ERROR: Refusing to install an ad-hoc signed app; it breaks Keychain access." >&2
        exit 1
    fi

    authority=$(awk -F= '/^Authority=/{print $2; exit}' <<<"$signing_info")
    if [[ -z "$authority" ]]; then
        echo "ERROR: Refusing to install an app without a signing authority; it breaks Keychain access." >&2
        exit 1
    fi

    designated_requirement=$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)
    if ! grep -Fq "identifier \"$BUNDLE_ID\"" <<<"$designated_requirement"; then
        echo "ERROR: The app signature does not match bundle id '$BUNDLE_ID'." >&2
        exit 1
    fi

    # The Keychain remembers which apps may read an item by team ID. An app signed
    # without a team is remembered by its code hash instead, which changes on every
    # build, so each new dev build would be asked for the API key again.
    team_identifier=$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$signing_info")
    if [[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID_PREFIX.dev" && "$team_identifier" != "$EXPECTED_DEV_TEAM_ID" ]]; then
        echo "ERROR: WhisperKey Dev must be signed with team $EXPECTED_DEV_TEAM_ID, not '${team_identifier:-none}'. The Keychain remembers an app with no team by its code hash, which changes on every build, so every install would ask for Keychain access again." >&2
        exit 1
    fi
}

verify_signature

if ! PROCESS_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST" 2>/dev/null); then
    echo "ERROR: '$APP_PATH' does not declare CFBundleExecutable." >&2
    exit 1
fi

USER_PREFS_DOMAIN="$HOME/Library/Preferences/$BUNDLE_ID"

mkdir -p "$DESTINATION_DIR"

APP_NAME="$(basename "$APP_PATH")"
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME"
TEMP_APP="$DESTINATION_DIR/.$APP_NAME.installing.$$"
IS_FRESH_INSTALL=0

if [[ ! -e "$DESTINATION_APP" ]]; then
    IS_FRESH_INSTALL=1
fi

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

require_running_app_to_be_stopped() {
    if ! pgrep -x "$PROCESS_NAME" >/dev/null 2>&1; then
        return
    fi

    if [[ "$STOP_RUNNING_APP" == "1" ]]; then
        terminate_running_app
        return
    fi

    echo "ERROR: $PROCESS_NAME is running. Quit it yourself before installing so its in-memory state is not lost. Set WHISPERKEY_INSTALL_STOP_RUNNING_APP=1 only when an explicit forced stop is intended." >&2
    exit 1
}

open_installed_app() {
    open -n "$DESTINATION_APP"
}

if [[ -e "$DESTINATION_APP" && "$APP_PATH" -ef "$DESTINATION_APP" ]]; then
    echo "WhisperKey is already installed at $DESTINATION_APP"
    require_running_app_to_be_stopped
    if [[ "$RESTART_AFTER_INSTALL" == "1" ]]; then
        open_installed_app
    fi
    exit 0
fi

cleanup() {
    rm -rf "$TEMP_APP"
}
trap cleanup EXIT

require_running_app_to_be_stopped
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

if [[ "$IS_FRESH_INSTALL" == "1" ]]; then
    show_welcome_on_next_launch
fi
if [[ "$RESTART_AFTER_INSTALL" == "1" ]]; then
    open_installed_app
fi

echo "Installed WhisperKey to $DESTINATION_APP"
