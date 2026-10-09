#!/usr/bin/env bash
# Download a published WhisperKey release and install it on this Mac.
#
# Usage: scripts/install-release.sh <version>      (e.g. 1.3.1)
#
# Downloads WhisperKey-<version>.dmg from the GitHub release v<version>, mounts
# it read-only, refuses an app that is not signed with Developer ID (ad-hoc or
# unsigned), replaces <destination>/WhisperKey.app with ditto, unmounts, removes
# com.apple.quarantine from the installed bundle if present, and prints the
# installed app's designated requirement.
#
# The destination defaults to /Applications. Only then is a running
# /Applications/WhisperKey.app quit before the copy and relaunched after it.
# WHISPERKEY_INSTALL_DESTINATION_DIR=<dir> installs somewhere else and never
# quits, kills or launches any WhisperKey process; it exists for testing.
#
# This script does not call install-app.sh: that script finds the running app
# by process name, so it would stop the live app even for a test destination.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 1.3.1" >&2
    exit 1
fi
VERSION="${VERSION#v}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

EXPECTED_BUNDLE_ID="yung-sun-xxi.WhisperKey"
APP_NAME="WhisperKey.app"
DMG_NAME="WhisperKey-$VERSION.dmg"
LIVE_DESTINATION_DIR="/Applications"

DESTINATION_DIR="${WHISPERKEY_INSTALL_DESTINATION_DIR:-$LIVE_DESTINATION_DIR}"
if [[ "$DESTINATION_DIR" != "/" ]]; then
    DESTINATION_DIR="${DESTINATION_DIR%/}"
fi
MANAGES_LIVE_APP=0
if [[ "$DESTINATION_DIR" == "$LIVE_DESTINATION_DIR" ]]; then
    MANAGES_LIVE_APP=1
fi
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME"
TEMP_APP="$DESTINATION_DIR/.$APP_NAME.installing.$$"

WORK_DIR="$(mktemp -d -t whisperkey-install-release)"
MOUNT_POINT="$WORK_DIR/mount"
DMG_PATH="$WORK_DIR/$DMG_NAME"
MOUNTED=0

unmount_dmg() {
    if [[ "$MOUNTED" != "1" ]]; then
        return 0
    fi
    if hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force -quiet; then
        MOUNTED=0
        echo "==> Unmounted $MOUNT_POINT"
        return 0
    fi
    echo "WARNING: Could not unmount $MOUNT_POINT; detach it with: hdiutil detach -force \"$MOUNT_POINT\"" >&2
    return 1
}

cleanup() {
    unmount_dmg || true
    rm -rf "$TEMP_APP"
    # Never delete the work folder while the image is still mounted inside it.
    if [[ "$MOUNTED" != "1" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

has_quarantine() {
    [[ -n "$(find "$1" -xattrname com.apple.quarantine -print -quit 2>/dev/null)" ]]
}

# Refuse anything but a WhisperKey release signed with Developer ID: an ad-hoc
# or unsigned app has a different designated requirement in every build, which
# costs Microphone, Accessibility and Keychain access on each install.
verify_release_signature() {
    local app="$1"
    local bundle_id
    local signing_info
    local authority
    local designated_requirement

    if [[ ! -f "$app/Contents/Info.plist" ]]; then
        echo "ERROR: The DMG does not contain $APP_NAME." >&2
        exit 1
    fi
    if ! bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null); then
        echo "ERROR: '$app' does not declare CFBundleIdentifier." >&2
        exit 1
    fi
    if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
        echo "ERROR: '$app' has bundle id '$bundle_id', expected '$EXPECTED_BUNDLE_ID'." >&2
        exit 1
    fi

    if ! /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
        echo "ERROR: Refusing to install v$VERSION: the app does not have a valid code signature." >&2
        exit 1
    fi

    signing_info=$(/usr/bin/codesign -dvv "$app" 2>&1)
    if grep -q '^Signature=adhoc$' <<<"$signing_info"; then
        echo "ERROR: Refusing to install v$VERSION: the app is ad-hoc signed, not signed with Developer ID." >&2
        exit 1
    fi
    authority=$(awk -F= '/^Authority=/{print $2; exit}' <<<"$signing_info")
    if [[ "$authority" != "Developer ID Application:"* ]]; then
        echo "ERROR: Refusing to install v$VERSION: the app is signed by '${authority:-nobody}', not a Developer ID Application certificate." >&2
        exit 1
    fi

    designated_requirement=$(/usr/bin/codesign -d -r- "$app" 2>&1)
    if ! grep -Fq "identifier \"$EXPECTED_BUNDLE_ID\"" <<<"$designated_requirement" \
        || grep -q 'cdhash' <<<"$designated_requirement"; then
        echo "ERROR: Refusing to install v$VERSION: unexpected designated requirement:" >&2
        echo "$designated_requirement" >&2
        exit 1
    fi
    echo "Signed by: $authority"
}

# PIDs of processes whose executable lives inside the installed bundle. Matching
# the path, not the process name, leaves WhisperKey Dev and any other copy alone.
running_app_pids() {
    local pid
    local command_path
    while read -r pid command_path; do
        if [[ "$command_path" == "$DESTINATION_APP/Contents/MacOS/"* ]]; then
            echo "$pid"
        fi
    done < <(ps -axo pid=,comm=)
}

wait_for_exit() {
    local attempts="$1"
    shift
    local pid
    for _ in $(seq "$attempts"); do
        local alive=0
        for pid in "$@"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=1
            fi
        done
        if [[ "$alive" == "0" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

quit_running_app() {
    local pids
    pids=$(running_app_pids)
    if [[ -z "$pids" ]]; then
        echo "==> $DESTINATION_APP is not running."
        return 0
    fi
    # shellcheck disable=SC2086 # one PID per word
    set -- $pids
    echo "==> Quitting $DESTINATION_APP (PID $*)..."
    kill -TERM "$@" 2>/dev/null || true
    if wait_for_exit 50 "$@"; then
        return 0
    fi
    echo "WARNING: WhisperKey did not quit within 5 s; killing it." >&2
    kill -KILL "$@" 2>/dev/null || true
    if ! wait_for_exit 20 "$@"; then
        echo "ERROR: Could not stop the running WhisperKey (PID $*)." >&2
        exit 1
    fi
}

echo "==> Downloading $DMG_NAME from release v$VERSION..."
gh release download "v$VERSION" --pattern "$DMG_NAME" --dir "$WORK_DIR"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: Release v$VERSION has no asset named $DMG_NAME." >&2
    exit 1
fi
if has_quarantine "$DMG_PATH"; then
    echo "Downloaded DMG quarantine: present"
else
    echo "Downloaded DMG quarantine: absent"
fi

echo "==> Mounting $DMG_NAME..."
mkdir -p "$MOUNT_POINT"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
MOUNTED=1
SOURCE_APP="$MOUNT_POINT/$APP_NAME"

echo "==> Verifying the release signature..."
verify_release_signature "$SOURCE_APP"

if [[ "$MANAGES_LIVE_APP" == "1" ]]; then
    quit_running_app
else
    echo "==> Destination is $DESTINATION_DIR, not $LIVE_DESTINATION_DIR: no WhisperKey process will be quit or launched."
fi

echo "==> Installing to $DESTINATION_APP..."
mkdir -p "$DESTINATION_DIR"
rm -rf "$TEMP_APP"
ditto "$SOURCE_APP" "$TEMP_APP"
rm -rf "$DESTINATION_APP"
mv "$TEMP_APP" "$DESTINATION_APP"

unmount_dmg

if has_quarantine "$DESTINATION_APP"; then
    xattr -dr com.apple.quarantine "$DESTINATION_APP"
    echo "Installed bundle quarantine: was present, removed"
else
    echo "Installed bundle quarantine: absent"
fi

/usr/bin/codesign --verify --deep --strict "$DESTINATION_APP"

if [[ "$MANAGES_LIVE_APP" == "1" ]]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [[ -x "$LSREGISTER" ]]; then
        "$LSREGISTER" -f "$DESTINATION_APP" >/dev/null 2>&1 || true
    fi
    echo "==> Launching $DESTINATION_APP..."
    open "$DESTINATION_APP"
fi

echo
echo "==> Designated requirement of $DESTINATION_APP:"
/usr/bin/codesign -d -r- "$DESTINATION_APP" 2>&1
echo
echo "Installed WhisperKey v$VERSION to $DESTINATION_APP"
