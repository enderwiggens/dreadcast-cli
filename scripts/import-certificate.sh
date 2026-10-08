#!/bin/sh
# Imports the Developer ID certificate into a temporary keychain that codesign can use
# without a prompt. For CI: MACOS_CERTIFICATE is the .p12, base64-encoded, and
# MACOS_CERTIFICATE_PASSWORD its password (see docs/RELEASING.md).
set -eu
: "${MACOS_CERTIFICATE:?}" "${MACOS_CERTIFICATE_PASSWORD:?}"
WORK="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$WORK/signing.keychain-db"
PASSWORD="$(uuidgen)"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
printf %s "$MACOS_CERTIFICATE" | base64 --decode > "$WORK/certificate.p12"
security import "$WORK/certificate.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
rm "$WORK/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# The certificate must be a valid signing identity; this prints its name, never the key.
security find-identity -v -p codesigning "$KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "Developer ID Application" || {
  echo "The certificate isn't a valid Developer ID Application identity." >&2
  exit 1
}
