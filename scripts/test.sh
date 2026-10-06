#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Use the selected Xcode; fall back to the installed Xcode when xcode-select points
# at the standalone Command Line Tools, which lack the testing libraries.
SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -z "${DEVELOPER_DIR:-}" && "$SELECTED_DEVELOPER_DIR" != *.app/Contents/Developer && -d /Applications/Xcode.app/Contents/Developer ]]; then
  SELECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"

xcrun swift test "$@"
