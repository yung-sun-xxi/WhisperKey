# Releasing WhisperKey

This document describes the owner release path for cutting a Developer
ID-signed, notarized DMG. Releases are manual; WhisperKey does not include an
in-app auto-update mechanism.

## Signing Inputs

The Xcode project keeps the app bundle identifier because it is part of the app
identity:

```text
yung-sun-xxi.WhisperKey
```

Machine-specific Apple signing values are configured outside git through
environment variables or an ignored local file named `release.local.env`.

Create `release.local.env` in the repository root:

```sh
WHISPERKEY_TEAM_ID=<APPLE_DEVELOPER_TEAM_ID>
WHISPERKEY_NOTARY_PROFILE=WhisperKey-Notary

# Optional. If omitted, scripts/release.sh uses the first Developer ID
# Application identity in the login keychain.
# WHISPERKEY_SIGN_IDENTITY="Developer ID Application: Your Name (<TEAM_ID>)"
```

`release.local.env` is ignored by git. The Team ID, bundle ID, and certificate
common name are not API secrets, but keeping them configurable makes the public
release flow reusable by forks and less owner-specific.

## One-time Setup

1. Confirm Apple Developer Program membership is active for the Team ID in
   `WHISPERKEY_TEAM_ID`.

2. Install the Developer ID Application certificate.

   In Xcode: Settings -> Accounts -> select team -> Manage Certificates -> +
   Developer ID Application.

   Verify it is available:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. Create an app-specific password at <https://appleid.apple.com> under
   Sign-In and Security -> App-Specific Passwords.

4. Store the notarytool profile. The profile name must match
   `WHISPERKEY_NOTARY_PROFILE`.

   ```sh
   xcrun notarytool store-credentials "$WHISPERKEY_NOTARY_PROFILE" \
       --apple-id "<your-apple-id>" \
       --team-id "$WHISPERKEY_TEAM_ID" \
       --password "<app-specific-password>"
   ```

   Verify:

   ```sh
   xcrun notarytool history --keychain-profile "$WHISPERKEY_NOTARY_PROFILE"
   ```

## Cutting a Release

From a clean checkout on `master`:

```sh
./scripts/release.sh 1.0.0
```

The script:

- Archives the app in Release configuration.
- Signs with Developer ID Application and hardened runtime.
- Exports with Developer ID distribution settings.
- Verifies the app signature.
- Submits the app to Apple notarization and staples the result.
- Builds and signs a DMG.
- Submits the DMG to Apple notarization and staples the result.
- Runs final Gatekeeper checks with `spctl`.
- Installs the notarized app into `/Applications/WhisperKey.app`.

Outputs:

- `build/export/WhisperKey.app` - signed, notarized, stapled app.
- `build/WhisperKey-<VERSION>.dmg` - signed, notarized, stapled DMG.
- `/Applications/WhisperKey.app` - installed app.

Publish:

```sh
gh release create v1.0.0 build/WhisperKey-1.0.0.dmg \
    --title "WhisperKey v1.0.0" \
    --notes-file <changelog-file>
```

## Automated Releases (GitHub Actions)

`.github/workflows/release.yml` runs the same `scripts/release.sh` on the
self-hosted macOS runner when a `v*` tag is pushed (or via manual
`workflow_dispatch` with a version input), then publishes/updates the GitHub
Release with the DMG.

The runner runs as a headless service, so the login keychain is locked and
unavailable for signing. To sign without depending on a GUI login session, the
release job uses a dedicated, isolated signing keychain whose password is the
only stored secret. That secret unlocks just this keychain (one certificate plus
the notary profile) rather than the whole login keychain.

### One-time runner setup

Run once on the runner machine, in a logged-in session (where the login keychain
is unlocked). Pick a strong password for the dedicated keychain and keep it.

```sh
CIPASS='<choose-a-strong-password>'
KEYCHAIN="$HOME/Library/Keychains/whisperkey-ci.keychain-db"

# 1. Create the dedicated keychain (no auto-lock timeout).
security create-keychain -p "$CIPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"

# 2. Import the Developer ID Application identity (cert + private key).
#    Export it first from Keychain Access: right-click the
#    "Developer ID Application: ..." identity -> Export -> .p12 (set P12PASS).
security import /path/to/DeveloperID.p12 -k "$KEYCHAIN" -P '<P12PASS>' \
    -T /usr/bin/codesign -T /usr/bin/productsign

# 3. Allow codesign to use the key non-interactively.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$CIPASS" "$KEYCHAIN"

# 4. Store the notarytool profile INTO this keychain.
xcrun notarytool store-credentials WhisperKey-Notary \
    --apple-id "<your-apple-id>" \
    --team-id "$WHISPERKEY_TEAM_ID" \
    --password "<app-specific-password>" \
    --keychain "$KEYCHAIN"
```

Then add the keychain password as a repository secret:

```sh
gh secret set SIGNING_KEYCHAIN_PASSWORD --body "$CIPASS"
```

`WHISPERKEY_TEAM_ID` is provided as a repository variable (already set); the
workflow reads it from `vars`.

### Owner-local secret storage

On the maintainer machine, release-only local secrets live outside the
repository in:

```text
/Users/a.stepanenkov/PersonalProjects/WhisperKey.local-secrets/
```

`whisperkey-ci-password.txt` must contain the same keychain password as the
GitHub repository secret `SIGNING_KEYCHAIN_PASSWORD`. Keep this file outside
git and update the GitHub secret whenever the dedicated CI keychain password is
rotated.

The Apple app-specific password is stored by `notarytool` in the
`WhisperKey-Notary` profile inside the dedicated signing keychain. Do not store
it in plaintext files, commit it, or paste it into issue/PR/release notes.

### Cutting an automated release

Push a tag, or dispatch manually:

```sh
git tag v1.2.0 && git push origin v1.2.0
# or
gh workflow run release.yml -f version=1.2.0
```

The job unlocks the dedicated keychain, builds/signs/notarizes via
`release.sh` (with `WHISPERKEY_SKIP_INSTALL=1`, so it does not touch
`/Applications`), and attaches the DMG to the release.

## If Notarization Fails

Pull the human-readable log:

```sh
xcrun notarytool log <submission-id> \
    --keychain-profile "$WHISPERKEY_NOTARY_PROFILE"
```

Common causes are missing hardened runtime, unsigned nested binaries,
secure-timestamp problems, or deprecated linking. Fix the issue, bump the build
number if needed, and re-run `./scripts/release.sh`.

## Entitlements

`WhisperKey/WhisperKey.entitlements` deliberately contains only
`com.apple.security.device.audio-input`.

App Sandbox is off because WhisperKey needs Accessibility, CGEventTap, and a
system-wide hotkey. Microphone and Accessibility are runtime TCC permissions,
not entitlements.

Do not add JIT, library-validation disable, AppleEvents, or dyld-env
entitlements unless there is a specific reviewed need. They widen the attack
surface and notarization may require a justification.
