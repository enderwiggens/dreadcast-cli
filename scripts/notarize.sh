#!/bin/sh
# Notarizes the zipped macOS binary and fails unless Apple accepts it, printing Apple's
# log when it doesn't. Then checks that Gatekeeper accepts the binary as notarized.
# NOTARY_KEY is an App Store Connect API key (.p8), base64-encoded; NOTARY_KEY_ID and
# NOTARY_ISSUER identify it (see docs/RELEASING.md).
#   scripts/notarize.sh dist/dread-macos-universal.zip dist/dread
set -eu
ARCHIVE="${1:?Usage: scripts/notarize.sh <zip> <binary>}"
BINARY="${2:?Usage: scripts/notarize.sh <zip> <binary>}"
: "${NOTARY_KEY:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf %s "$NOTARY_KEY" | base64 --decode > "$WORK/key.p8"

notary() { xcrun notarytool "$@" --key "$WORK/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"; }

notary submit "$ARCHIVE" --wait --timeout 2h --output-format json > "$WORK/result.json"
STATUS="$(plutil -extract status raw -o - "$WORK/result.json")"
ID="$(plutil -extract id raw -o - "$WORK/result.json")"
echo "Notarization $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  notary log "$ID" || true
  exit 1
fi

spctl --assess --type execute -vv "$BINARY" 2>&1 | tee "$WORK/gatekeeper.txt"
grep -q "source=Notarized Developer ID" "$WORK/gatekeeper.txt" || {
  echo "Gatekeeper doesn't see $BINARY as notarized." >&2
  exit 1
}
