#!/bin/sh
# Exercises a built dread without the network: help, exit codes, setup and saved places
# from coordinates, config, scene rendering and PNG output, and credits. CI and the
# release run it against the static Linux binary; run it locally with any build:
#   scripts/smoke-test.sh .build/release/dread
set -eu

BIN="${1:?Usage: scripts/smoke-test.sh <path-to-dread>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export DREADCAST_CONFIG_DIR="$WORK/config" DREADCAST_CACHE_DIR="$WORK/cache" DREADCAST_CREDENTIAL_STORE=none NO_COLOR=1

fail() { echo "smoke test failed: $*" >&2; exit 1; }
exit_code() { set +e; "$@" > /dev/null 2>&1; code=$?; set -e; echo "$code"; }

"$BIN" version | grep -q '^dread [0-9]' || fail "version"
for topic in "" top places scene radar alerts config prompt eta; do
  "$BIN" help $topic > /dev/null || fail "help $topic"
done

# Commands that need a place exit 4 before setup.
[ "$(exit_code "$BIN" now --plain)" -eq 4 ] || fail "now before setup should exit 4"

# Coordinates need no network.
"$BIN" setup 40.71,-74.01 --plain > /dev/null || fail "setup"
"$BIN" places add 51.51,-0.13 --name london --plain > /dev/null || fail "places add"
"$BIN" places --json | grep -q 'london' || fail "places --json"
[ "$(exit_code "$BIN" places add 51.51,-0.13 --plain)" -eq 2 ] || fail "a duplicate place should exit 2"

"$BIN" config set units metric --plain > /dev/null || fail "config set"
"$BIN" config --json | grep -q 'metric' || fail "config --json"
[ "$(exit_code "$BIN" config set units kelvin --plain)" -eq 2 ] || fail "a bad config value should exit 2"

# Rendering: the scene painter and the PNG encoder.
"$BIN" scene asteroid --time night --png "$WORK/scene.png" --size 80x24 > /dev/null || fail "scene --png"
[ "$(head -c 8 "$WORK/scene.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] || fail "scene --png wrote no PNG"
"$BIN" scene uap --still --plain > /dev/null || fail "scene --still"

"$BIN" credits --plain | grep -q 'NOAA MRMS' || fail "credits"

echo "smoke test passed: $("$BIN" version)"
