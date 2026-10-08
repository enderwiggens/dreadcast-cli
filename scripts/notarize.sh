#!/bin/sh
# Notarizes the zipped macOS binary and fails unless Apple accepts it, printing Apple's
# log when it doesn't. Then checks that Gatekeeper accepts the binary as notarized.
# NOTARY_TIMEOUT_MINUTES (default 240) limits the wait.
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

notary submit "$ARCHIVE" --output-format json > "$WORK/submit.json"
ID="$(plutil -extract id raw -o - "$WORK/submit.json")"
echo "Submitted for notarization: $ID"

# Apple usually answers within minutes, but a team's first submissions can take hours.
# The submission keeps processing whatever happens here, so network errors while
# checking on it are retried rather than failing the release.
DEADLINE=$(( $(date +%s) + ${NOTARY_TIMEOUT_MINUTES:-240} * 60 ))
while :; do
  if notary info "$ID" --output-format json > "$WORK/info.json" 2> "$WORK/error.txt"; then
    STATUS="$(plutil -extract status raw -o - "$WORK/info.json")"
    case "$STATUS" in
      Accepted) break ;;
      "In Progress") ;;
      *)
        echo "Notarization $ID: $STATUS" >&2
        notary log "$ID" || true
        exit 1
        ;;
    esac
  else
    echo "Couldn't reach the notary service ($(head -c 200 "$WORK/error.txt")); retrying." >&2
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "Apple is still processing notarization $ID (check it with \`xcrun notarytool info $ID\`). Rerun the job later: once a team's first submissions clear, notarization usually takes minutes." >&2
    exit 1
  fi
  sleep 30
done
echo "Notarization $ID: Accepted"

# Gatekeeper looks the ticket up online, so a failed check is retried a few times. A
# command-line tool is assessed as a file to open: `--type execute` only accepts apps
# and calls a bare binary "not an app" even when it's notarized.
for attempt in 1 2 3 4 5; do
  spctl --assess --type open --context context:primary-signature -vv "$BINARY" > "$WORK/gatekeeper.txt" 2>&1 || true
  if grep -q "source=Notarized Developer ID" "$WORK/gatekeeper.txt"; then
    cat "$WORK/gatekeeper.txt"
    exit 0
  fi
  sleep 20
done
cat "$WORK/gatekeeper.txt" >&2
echo "Gatekeeper doesn't see $BINARY as notarized." >&2
exit 1
