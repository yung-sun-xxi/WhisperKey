#!/usr/bin/env bash
# Build, sign, notarize, and package WhisperKey for distribution.
#
# Prerequisites (one-time, see RELEASING.md):
#   - Developer ID Application certificate installed in the login keychain
#   - WHISPERKEY_TEAM_ID set in the environment or release.local.env
#   - notarytool keychain profile stored; defaults to "WhisperKey-Notary"
#   - VERSION must be passed as the first argument (e.g. ./scripts/release.sh 1.0.0)
#
# Output:
#   build/export/WhisperKey.app   (signed, notarized, stapled)
#   build/WhisperKey-<VERSION>.dmg (signed, notarized, stapled)

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

TEAM_ID="${WHISPERKEY_TEAM_ID:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "ERROR: WHISPERKEY_TEAM_ID is required." >&2
    echo "Set it in the environment or create release.local.env from RELEASING.md." >&2
    exit 1
fi

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

# Resolve the Developer ID Application identity (requires exactly one match).
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning login.keychain-db \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "ERROR: No 'Developer ID Application' identity found in the login keychain." >&2
    echo "Open Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application." >&2
    exit 1
fi
echo "Using signing identity: $SIGN_IDENTITY"

# Verify the saved notarytool credential profile exists.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notarytool profile '$NOTARY_PROFILE' is not stored." >&2
    echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "         --apple-id <APPLE_ID> --team-id $TEAM_ID --password <APP_SPECIFIC_PASSWORD>" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

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

echo "==> Archiving (Release, hardened runtime, manual signing)..."
XCODEBUILD_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration Release
    -derivedDataPath "$BUILD_DIR/dd"
    -archivePath "$ARCHIVE_PATH"
    clean archive
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    DEVELOPMENT_TEAM="$TEAM_ID"
    MARKETING_VERSION="$VERSION"
)
if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "${XCODEBUILD_ARGS[@]}" | xcbeautify
else
    xcodebuild "${XCODEBUILD_ARGS[@]}"
fi

echo "==> Exporting archive with Developer ID method..."
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

echo "==> Verifying app signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=2 "$APP_PATH" 2>&1 | head -10

echo "==> Zipping app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting app to notarytool (this can take several minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling app..."
xcrun stapler staple "$APP_PATH"

echo "==> Creating DMG..."
hdiutil create \
    -volname WhisperKey \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "==> Signing DMG..."
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Submitting DMG to notarytool..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling DMG..."
xcrun stapler staple "$DMG_PATH"

echo "==> Final verification..."
spctl --assess --verbose=4 --type install "$DMG_PATH"
spctl --assess --verbose=4 --type execute "$APP_PATH"

echo "==> Installing app to /Applications..."
"$SCRIPT_DIR/install-app.sh" "$APP_PATH"

echo
echo "Done. Artifacts:"
echo "  $APP_PATH"
echo "  $DMG_PATH"
echo "  /Applications/WhisperKey.app"
echo
echo "Next: gh release create v$VERSION $DMG_PATH --title \"WhisperKey v$VERSION\" --notes-file <changelog>"
