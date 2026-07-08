#!/usr/bin/env bash
# Creates a stable local code-signing identity for Debug builds.

set -euo pipefail

CERT_NAME="${WHISPERKEY_LOCAL_SIGNING_CERT:-WhisperKey Local Development}"
KEYCHAIN="${WHISPERKEY_LOCAL_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Local signing certificate already exists: $CERT_NAME"
    exit 0
fi

TMPDIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

P12_PASSWORD="whisperkey-local-dev"
CERT_PEM="$TMPDIR/cert.pem"
KEY_PEM="$TMPDIR/key.pem"
P12="$TMPDIR/cert.p12"

openssl req -newkey rsa:2048 -nodes -x509 -days 3650 \
    -subj "/CN=$CERT_NAME/" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$KEY_PEM" \
    -out "$CERT_PEM" >/dev/null 2>&1

openssl pkcs12 -legacy -export \
    -inkey "$KEY_PEM" \
    -in "$CERT_PEM" \
    -name "$CERT_NAME" \
    -out "$P12" \
    -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate >/dev/null

security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN" \
    "$CERT_PEM" >/dev/null

echo "Created local signing certificate: $CERT_NAME"
