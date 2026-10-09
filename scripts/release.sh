#!/usr/bin/env bash
# Build and package WhisperKey for distribution.
#
# Prerequisites (one-time, see RELEASING.md):
#   - Default (Developer ID) mode: Developer ID Application certificate and
#     WHISPERKEY_TEAM_ID. A notarytool keychain profile is used when it works.
#   - Ad-hoc mode, for when the certificate itself is unavailable:
#     WHISPERKEY_RELEASE_MODE=ad-hoc.
#   - VERSION must be passed as the first argument (e.g. ./scripts/release.sh 1.0.0)
#
# Developer ID mode always signs with Developer ID and the hardened runtime,
# then attempts notarization. A missing or rejected notarytool profile, or a
# failed submit or staple, is a warning: the build completes signed but not
# notarized, with an INSTALL.txt in the DMG explaining the one-time approval.
#
# Output:
#   build/export/WhisperKey.app
#   build/WhisperKey-<VERSION>.dmg
#   build/notarization.txt  one word: notarized, not-notarized or ad-hoc

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 1.0.0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CONFIG_PATH="${WHISPERKEY_RELEASE_CONFIG:-release.local.env}"
if [[ "$CONFIG_PATH" != /* ]]; then
    CONFIG_PATH="$REPO_ROOT/$CONFIG_PATH"
fi
if [[ -f "$CONFIG_PATH" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_PATH"
fi

RELEASE_MODE="${WHISPERKEY_RELEASE_MODE:-developer-id}"
case "$RELEASE_MODE" in
    developer-id | ad-hoc) ;;
    *)
        echo "ERROR: WHISPERKEY_RELEASE_MODE must be 'developer-id' or 'ad-hoc'." >&2
        exit 1
        ;;
esac

SCHEME="WhisperKey"
PROJECT="WhisperKey.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/WhisperKey.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_PATH/WhisperKey.app"
DMG_PATH="$BUILD_DIR/WhisperKey-$VERSION.dmg"
ZIP_PATH="$BUILD_DIR/WhisperKey-$VERSION.zip"
NOTARY_PROFILE="${WHISPERKEY_NOTARY_PROFILE:-WhisperKey-Notary}"
SIGN_IDENTITY="${WHISPERKEY_SIGN_IDENTITY:-}"
KEYCHAIN="${WHISPERKEY_KEYCHAIN:-login.keychain-db}"
NOTARIZE=0
NOTARIZATION_FILE="$BUILD_DIR/notarization.txt"

if [[ "$RELEASE_MODE" == "developer-id" ]]; then
    TEAM_ID="${WHISPERKEY_TEAM_ID:-}"
    if [[ -z "$TEAM_ID" ]]; then
        echo "ERROR: WHISPERKEY_TEAM_ID is required." >&2
        echo "Set it in the environment or create release.local.env from RELEASING.md." >&2
        exit 1
    fi

    # Resolve the Developer ID Application identity (requires exactly one match).
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" \
            | awk -F'"' '/Developer ID Application/ {print $2; exit}')
    fi
    if [[ -z "${SIGN_IDENTITY:-}" ]]; then
        echo "ERROR: No 'Developer ID Application' identity found in the login keychain." >&2
        echo "Open Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application." >&2
        exit 1
    fi
    echo "Using signing identity: $SIGN_IDENTITY"

    # notarytool takes --keychain only as a path; `security` also accepts a bare
    # keychain name such as the default login.keychain-db.
    NOTARY_KEYCHAIN="$KEYCHAIN"
    if [[ "$NOTARY_KEYCHAIN" != */* ]]; then
        NOTARY_KEYCHAIN="$HOME/Library/Keychains/$NOTARY_KEYCHAIN"
    fi

    # Check that the saved notarytool profile exists and Apple accepts it.
    # Either failure leaves the build signed but not notarized.
    if NOTARY_CHECK_OUTPUT=$(xcrun notarytool history \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$NOTARY_KEYCHAIN" 2>&1); then
        NOTARIZE=1
    else
        NOTARIZE=0
        echo "WARNING: notarytool profile '$NOTARY_PROFILE' is missing or rejected; the build will be signed with Developer ID but not notarized." >&2
        echo "notarytool: $(grep -m1 -i 'error' <<<"$NOTARY_CHECK_OUTPUT" || head -1 <<<"$NOTARY_CHECK_OUTPUT")" >&2
        echo "If the profile is missing, store it with: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
        echo "         --apple-id <APPLE_ID> --team-id $TEAM_ID --password <APP_SPECIFIC_PASSWORD>" >&2
    fi
else
    echo "Using temporary ad-hoc release mode; Apple notarization will be skipped."
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if [[ "$RELEASE_MODE" == "developer-id" ]]; then
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
fi

# The scheme's "Install to /Applications" build phase also runs on archive. This
# script installs the exported app itself at the end (or skips that with
# WHISPERKEY_SKIP_INSTALL=1), so the archive must never install anything.
export WHISPERKEY_SKIP_APPLICATIONS_INSTALL=1

echo "==> Archiving Release build..."
XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration Release
    -derivedDataPath "$BUILD_DIR/dd"
    -archivePath "$ARCHIVE_PATH"
    clean archive
    MARKETING_VERSION="$VERSION"
)
if [[ "$RELEASE_MODE" == "developer-id" ]]; then
    XCODEBUILD_ARGS+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
        DEVELOPMENT_TEAM="$TEAM_ID"
    )
else
    XCODEBUILD_ARGS+=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )
fi
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${XCODEBUILD_ARGS[@]}" | xcbeautify
else
    xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

if [[ "$RELEASE_MODE" == "developer-id" ]]; then
    echo "==> Exporting archive with Developer ID method..."
    xcodebuild \
        -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
else
    echo "==> Applying an ad-hoc signature..."
    mkdir -p "$EXPORT_PATH"
    ditto "$ARCHIVE_PATH/Products/Applications/WhisperKey.app" "$APP_PATH"
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "==> Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=2 "$APP_PATH" 2>&1 | head -10

APP_NOTARIZED=0
if [[ "$RELEASE_MODE" == "developer-id" && "$NOTARIZE" == "1" ]]; then
    echo "==> Zipping app for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "==> Submitting app to notarytool (this can take several minutes)..."
    if ! xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --keychain "$NOTARY_KEYCHAIN" \
        --wait; then
        echo "WARNING: App notarization failed; continuing signed with Developer ID, not notarized." >&2
    else
        echo "==> Stapling app..."
        if ! xcrun stapler staple "$APP_PATH"; then
            echo "WARNING: Stapling the app failed; continuing signed with Developer ID, not notarized." >&2
        else
            APP_NOTARIZED=1
        fi
    fi
fi

echo "==> Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/WhisperKey.app"
ln -s /Applications "$DMG_STAGING/Applications"
if [[ "$RELEASE_MODE" == "ad-hoc" ]]; then
    cat > "$DMG_STAGING/INSTALL.txt" <<'EOF'
WhisperKey temporary release

This build is not notarized by Apple. To open it once:

1. Drag WhisperKey.app to Applications.
2. Try to open WhisperKey.app.
3. Open System Settings > Privacy & Security and click Open Anyway.
4. Confirm Open.

After that one-time approval, WhisperKey opens normally.
EOF
elif [[ "$APP_NOTARIZED" != "1" ]]; then
    cat > "$DMG_STAGING/INSTALL.txt" <<'EOF'
WhisperKey release, signed but not notarized

This build is signed with the developer's Developer ID certificate but is
not notarized by Apple. If you downloaded it in a browser, macOS asks once
before the first launch:

1. Drag WhisperKey.app to Applications.
2. Try to open WhisperKey.app.
3. Open System Settings > Privacy & Security and click Open Anyway.
4. Confirm Open.

After that one-time approval, WhisperKey opens normally.
EOF
fi
hdiutil create \
    -volname WhisperKey \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
rm -rf "$DMG_STAGING"

if [[ "$RELEASE_MODE" == "developer-id" ]]; then
    echo "==> Signing DMG..."
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

    DMG_NOTARIZED=0
    if [[ "$APP_NOTARIZED" == "1" ]]; then
        echo "==> Submitting DMG to notarytool..."
        if ! xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --keychain "$NOTARY_KEYCHAIN" \
            --wait; then
            echo "WARNING: DMG notarization failed; the app inside is notarized, the DMG is not." >&2
        else
            echo "==> Stapling DMG..."
            if ! xcrun stapler staple "$DMG_PATH"; then
                echo "WARNING: Stapling the DMG failed; the app inside is notarized, the DMG is not." >&2
            else
                DMG_NOTARIZED=1
            fi
        fi
    fi

    if [[ "$APP_NOTARIZED" == "1" && "$DMG_NOTARIZED" == "1" ]]; then
        NOTARIZATION_RESULT="notarized"
        echo "==> Final Gatekeeper verification..."
        spctl --assess --verbose=4 --type install "$DMG_PATH"
        spctl --assess --verbose=4 --type execute "$APP_PATH"
    else
        NOTARIZATION_RESULT="not-notarized"
        echo "==> Skipping Gatekeeper assessment: it rejects a Developer ID build that is not notarized."
    fi
else
    NOTARIZATION_RESULT="ad-hoc"
    echo "==> Ad-hoc build verified. Gatekeeper approval is required on each user's Mac."
fi
echo "$NOTARIZATION_RESULT" > "$NOTARIZATION_FILE"

if [[ "${WHISPERKEY_SKIP_INSTALL:-0}" == "1" ]]; then
    echo "==> Skipping install to /Applications (WHISPERKEY_SKIP_INSTALL=1)."
else
    echo "==> Installing app to /Applications..."
    "$SCRIPT_DIR/install-app.sh" "$APP_PATH"
fi

echo
echo "==> Designated requirement of $APP_PATH:"
codesign -d -r- "$APP_PATH" 2>&1

case "$NOTARIZATION_RESULT" in
    notarized) RELEASE_TITLE="WhisperKey v$VERSION" ;;
    not-notarized) RELEASE_TITLE="WhisperKey v$VERSION (not notarized)" ;;
    *) RELEASE_TITLE="WhisperKey v$VERSION (temporary ad-hoc build)" ;;
esac

echo
echo "Done ($NOTARIZATION_RESULT). Artifacts:"
echo "  $APP_PATH"
echo "  $DMG_PATH"
echo "  $NOTARIZATION_FILE"
if [[ "${WHISPERKEY_SKIP_INSTALL:-0}" != "1" ]]; then
    echo "  /Applications/WhisperKey.app"
fi
echo
echo "Next: gh release create v$VERSION $DMG_PATH --title \"$RELEASE_TITLE\" --notes-file <changelog>"
