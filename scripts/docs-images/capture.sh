#!/bin/zsh
# Regenerates the README screenshots in docs/images from live runs of dread.
#
# Needs network access, Google Chrome (or CHROME=/path/to/chromium) and a Python with
# pyte: `python3 -m venv .venv && .venv/bin/pip install pyte`, then
# `PYTHON=.venv/bin/python scripts/docs-images/capture.sh`.
#
# DREAD_DOCS_LOCATION and DREAD_DOCS_ALERT_LOCATION choose the places shown; pick an
# alert location with an active NWS alert so the alerts example has something to show.
set -euo pipefail
cd "${0:A:h}/../.."

PYTHON=${PYTHON:-python3}
LOCATION=${DREAD_DOCS_LOCATION:-33602}
ALERT_LOCATION=${DREAD_DOCS_ALERT_LOCATION:-$LOCATION}
OUT=docs/images
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift build -c release --product dread >/dev/null
BIN=$PWD/.build/release/dread
T2P=(${=PYTHON} scripts/docs-images/term2png.py)

# A private config and cache, so the screenshots never touch your own settings.
export DREADCAST_CONFIG_DIR=$WORK/config DREADCAST_CACHE_DIR=$WORK/cache
export COLORTERM=truecolor TERM=xterm-256color DREAD_GRAPHICS=none LANG=en_US.UTF-8 PYTHONDONTWRITEBYTECODE=1
mkdir -p $DREADCAST_CONFIG_DIR $OUT
print '{"version":1,"scene":"asteroid"}' > $DREADCAST_CONFIG_DIR/config.json

# Inline commands: no terminal attached, so the size comes from COLUMNS and LINES.
# MAX_ROWS keeps only the first rows, for long output such as full alert text.
shot() {
  local name=$1 columns=$2
  shift 2
  COLUMNS=$columns LINES=44 $BIN "$@" --pretty < /dev/null > $WORK/$name.ansi 2> $WORK/$name.log || true
  local limit=()
  [[ -n ${MAX_ROWS:-} ]] && limit=(--max-rows $MAX_ROWS)
  $T2P inline $WORK/$name.ansi $OUT/$name.png --cols $columns $limit
  print "  $OUT/$name.png"
}

# `dread` uses a radar nowcast only when one is already cached, as it would be in daily use.
COLUMNS=100 $BIN eta --location $LOCATION --plain < /dev/null > /dev/null 2>&1 || true
shot dread 96 --location $LOCATION
shot forecast 100 forecast --location $LOCATION
shot radar 100 radar --still --range 150 --location $LOCATION
shot eta 100 eta --location $LOCATION
shot outlook 100 outlook --location $LOCATION
MAX_ROWS=30 shot alerts 100 alerts --location $ALERT_LOCATION

# Full-screen commands run in a pseudo-terminal.
$T2P pty $OUT/top.png --cols 108 --rows 32 --wait 10 -- $BIN top --location $LOCATION
print "  $OUT/top.png"
$T2P pty $OUT/scene.png --cols 100 --rows 34 --wait 3 -- $BIN scene asteroid --time dusk --location $LOCATION
print "  $OUT/scene.png"

# Every free scene at dusk.
items=()
for scene in asteroid deep-trouble ai-uprising solar-tantrum fallout superstorm clear-for-now uap; do
  $BIN scene $scene --time dusk --png $WORK/$scene.png --size 96x16 > /dev/null
  items+=("$($BIN scene $scene --json | ${=PYTHON} -c 'import json,sys; print(json.load(sys.stdin)["title"])')=$WORK/$scene.png")
done
$T2P gallery $OUT/scenes.png "${items[@]}"
print "  $OUT/scenes.png"
