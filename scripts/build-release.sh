#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="${1:?Usage: scripts/build-release.sh <version>}"

SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -z "${DEVELOPER_DIR:-}" && "$SELECTED_DEVELOPER_DIR" != *.app/Contents/Developer && -d /Applications/Xcode.app/Contents/Developer ]]; then
  SELECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"

grep -q "version = \"$VERSION\"" Sources/DreadcastKit/HTTP.swift || {
  echo "Sources/DreadcastKit/HTTP.swift does not declare version $VERSION." >&2
  exit 1
}

xcrun swift build -c release --arch arm64 --arch x86_64
mkdir -p dist
cp .build/apple/Products/Release/dread dist/dread

if [[ -n "${DREADCAST_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DREADCAST_SIGNING_IDENTITY" dist/dread
  codesign --verify --strict dist/dread
fi

lipo -info dist/dread
# A flat zip with only the binary: no parent folder, resource forks or extended attributes.
ARCHIVE="dread-macos-universal.zip"
(cd dist && rm -f "$ARCHIVE" && ditto -c -k --norsrc --noextattr --noqtn --noacl dread "$ARCHIVE" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Built dist/$ARCHIVE"
