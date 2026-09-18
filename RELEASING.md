# Releasing WhisperKey

This document describes the normal Developer ID-signed, notarized release path
and the temporary ad-hoc fallback for when the Developer ID certificate is
unavailable. Releases are manual; WhisperKey does not include an in-app
auto-update mechanism.

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

## Temporary ad-hoc releases

Use this only when the Developer ID certificate is unavailable or revoked.
The script builds without the unavailable Developer ID certificate, then applies
an ad-hoc signature so the app bundle is internally consistent. It does not
submit anything to Apple notarization.

```sh
WHISPERKEY_RELEASE_MODE=ad-hoc WHISPERKEY_SKIP_INSTALL=1 \
  ./scripts/release.sh 1.1.7
```

The generated DMG includes an `INSTALL.txt`. On the first launch, each user
must open System Settings → Privacy & Security and choose **Open Anyway** for
WhisperKey. After that one-time approval, the app opens normally. Do not remove
the existing signature from a Developer ID build: a revoked signature can make
Gatekeeper treat the app as compromised and move it to the Trash.

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

The runner is a LaunchAgent in the owner's desktop session, so the login
keychain is his live one and the job never writes to it. Instead the release job
builds a keychain of its own under `$RUNNER_TEMP`, with a password generated
inside the job, imports the Developer ID identity and the notarytool profile
into it from repository secrets, signs and notarizes, and deletes it in a
post-step that also restores the user keychain search list. Nothing persists on
the runner between runs, and the owner has no second keychain password to know.

### Repository secrets and variables

| Name | Kind | Value |
|------|------|-------|
| `SIGNING_CERTIFICATE_P12_BASE64` | secret | The `Developer ID Application` identity (certificate + private key) as a base64-encoded `.p12`, legacy PKCS#12 encryption |
| `SIGNING_CERTIFICATE_PASSWORD` | secret | Password of that `.p12` |
| `NOTARY_APPLE_ID` | secret | Apple ID used for notarization |
| `NOTARY_APP_SPECIFIC_PASSWORD` | secret | App-specific password for that Apple ID |
| `WHISPERKEY_TEAM_ID` | variable | Team ID |

To regenerate the certificate secret after the identity is reissued, export it
from the login keychain and re-encode. `security export` writes every identity in
the keychain, so filter to the one certificate first:

```sh
P12PASS=$(openssl rand -hex 24)
security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 \
    -P "$P12PASS" -o all.p12
openssl pkcs12 -legacy -in all.p12 -passin pass:"$P12PASS" -nodes -out all.pem
# keep only the "Developer ID Application" key and certificate from all.pem
openssl pkcs12 -export -legacy -inkey devid.key -in devid.crt \
    -name "Developer ID Application: ALEXANDER STEPANENKOV (UGLRY9ACZ6)" \
    -passout pass:"$P12PASS" -out devid.p12
base64 < devid.p12 | gh secret set SIGNING_CERTIFICATE_P12_BASE64
printf %s "$P12PASS" | gh secret set SIGNING_CERTIFICATE_PASSWORD
rm all.p12 all.pem devid.key devid.crt devid.p12
```

`-legacy` matters: `security import` rejects the AES-encrypted PKCS#12 that
OpenSSL 3 writes by default ("MAC verification failed").

The Apple app-specific password lives only in the repository secret and, on the
maintainer machine, in the login keychain as the `WhisperKey-Notary` notarytool
profile. Do not store it in plaintext files, commit it, or paste it into
issue/PR/release notes.

### Cutting an automated release

Push a tag, or dispatch manually:

```sh
git tag v1.2.0 && git push origin v1.2.0
# or
gh workflow run release.yml -f version=1.2.0
```

The job creates its temporary signing keychain, builds/signs/notarizes via
`release.sh` (with `WHISPERKEY_SKIP_INSTALL=1`, so it does not touch
`/Applications`), removes the keychain, and attaches the DMG to the release.

A tag build uses `developer-id` mode and notarizes through Apple. Dispatching
manually accepts either mode through the `release_mode` input; `ad-hoc` is a
fallback for when the Developer ID certificate or notarization is unavailable.

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

`WhisperKey/WhisperKey.entitlements` contains microphone access and Apple
Events automation. The latter is required to pause and resume Apple Music
during recording.

App Sandbox is off because WhisperKey needs Accessibility, CGEventTap, and a
system-wide hotkey. Microphone and Accessibility are runtime TCC permissions,
not entitlements.

Do not add JIT, library-validation disable, or dyld-env entitlements unless
there is a specific reviewed need. They widen the attack surface and
notarization may require a justification.
