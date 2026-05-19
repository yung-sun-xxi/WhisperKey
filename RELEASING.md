# Releasing WhisperKey

Cutting a Developer ID-signed, notarized DMG. Manual process; no in-app auto-update.

## One-time setup (per machine)

1. **Apple Developer Program membership** is active for team `UGLRY9ACZ6`.

2. **Install the Developer ID Application certificate.**

   In Xcode: *Settings → Accounts → (select team) → Manage Certificates → + → Developer ID Application*. Verify it landed in the login keychain:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **Create an app-specific password** at <https://appleid.apple.com> (Sign-In and Security → App-Specific Passwords).

4. **Store the notarytool profile** (the release script reads it by name):

   ```sh
   xcrun notarytool store-credentials WhisperKey-Notary \
       --apple-id "<your-apple-id>" \
       --team-id UGLRY9ACZ6 \
       --password "<app-specific-password>"
   ```

   Verify:

   ```sh
   xcrun notarytool history --keychain-profile WhisperKey-Notary
   ```

## Cutting a release

From a clean checkout on `master`:

```sh
./scripts/release.sh 1.0.0
```

The script archives Release, exports with `developer-id` method (manual signing, hardened runtime), verifies the signature, submits the app to notarytool and waits, staples, builds and signs a DMG, submits and staples the DMG, and runs final `spctl` checks.

Outputs:

- `build/export/WhisperKey.app` — signed, notarized, stapled
- `build/WhisperKey-<VERSION>.dmg` — signed, notarized, stapled
- `/Applications/WhisperKey.app` — installed from the signed, notarized, stapled app

Publish:

```sh
gh release create v1.0.0 build/WhisperKey-1.0.0.dmg \
    --title "WhisperKey v1.0.0" \
    --notes "<changelog>"
```

## If notarization fails

Pull the human-readable log:

```sh
xcrun notarytool log <submission-id> --keychain-profile WhisperKey-Notary
```

Common causes: missing hardened runtime, unsigned nested binary, secure-timestamp problems, deprecated linking. Fix the issue, bump the build number, and re-run `./scripts/release.sh`.

## Entitlements

`WhisperKey/WhisperKey.entitlements` deliberately contains only `com.apple.security.device.audio-input`. App Sandbox is **off** (we need Accessibility / CGEventTap and a system-wide hotkey). Microphone and Accessibility are runtime TCC permissions, not entitlements. Do not add JIT, library-validation disable, AppleEvents, or dyld-env entitlements — they widen the attack surface and notarization will demand a justification.
